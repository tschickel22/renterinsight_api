# frozen_string_literal: true

module Websites
  # The homes list on Edit Website, Inventory: every home this site could
  # show (the statuses its inventory sections and the company publish), with
  # its asking price and where that comes from, what a buyer sees, and
  # whether a rule or its own switch hides it here.
  #
  # Asking price is Truebuild::InventoryPricing#list_price (the inventory
  # list's one price), unless the home is on sale in this site's Featured
  # Homes with "Display sale pricing on website" on, which shows whatever the
  # site's switch says.
  class InventoryHomes
    PER_PAGE = 50

    def initialize(website, settings: nil)
      @website = website
      @company = website.company
      @settings = settings || InventorySettings.new(website)
    end

    # Statuses this site's inventory sections ask for, plus the company's
    # public statuses (what a section that names none shows).
    def statuses
      @statuses ||= begin
        found = []
        @website.website_pages.where(is_deleted: [false, nil]).pluck(:blocks).each { |b| collect_statuses(b, found) }
        (company_statuses | found.map { |s| s.to_s.strip }.reject(&:blank?)).uniq
      end
    end

    def scope
      @company.vehicles.where(is_deleted: [false, nil], status: statuses)
    end

    # Values to offer in "Add" for each rule field.
    def options
      base = scope
      series = base.where.not(catalog_plan_variant_id: nil).joins(catalog_plan_variant: :catalog_plan)
                   .distinct.pluck('catalog_plans.series')
      series |= base.where.not(champion_series_name: [nil, '']).distinct.pluck(:champion_series_name)
      {
        make: clean(base.distinct.pluck(:make)),
        series: clean(series),
        model: clean(base.distinct.pluck(:model)),
        status: base.distinct.pluck(:status).compact.sort.map { |s| { value: s, label: status_label(s) } }
      }
    end

    def counts
      total = scope.count
      shown = @settings.visible(scope).count
      { total: total, shown: shown, hidden: total - shown }
    end

    def page(search: nil, page: 1, per_page: PER_PAGE)
      rows = scope
      if search.present?
        term = "%#{ActiveRecord::Base.sanitize_sql_like(search.to_s.strip)}%"
        rows = rows.where('vehicles.make ILIKE :t OR vehicles.model ILIKE :t OR vehicles.stock_number ILIKE :t ' \
                          'OR vehicles.inventory_id ILIKE :t OR vehicles.vin ILIKE :t OR CAST(vehicles.year AS TEXT) ILIKE :t', t: term)
      end
      filtered = rows.count
      per_page = per_page.to_i.clamp(1, 100)
      page = [page.to_i, 1].max
      vehicles = rows.includes(:location, catalog_plan_variant: :catalog_plan)
                     .order(:make, :model, :year, :id).offset((page - 1) * per_page).limit(per_page).to_a
      featured = featured_sales(vehicles)

      { items: vehicles.map { |v| row(v, featured[v.id]) },
        meta: { filtered: filtered, page: page, per_page: per_page, total_pages: (filtered.to_f / per_page).ceil } }
    end

    private

    def row(vehicle, featured_sale)
      asking = list_price(vehicle)
      book = asking && asking[:source] == 'book' ? inventory_pricing.breakdown(vehicle, include_cost: false) : nil
      shown_price = public_price.price(vehicle)
      rule = @settings.rule_for(vehicle)
      {
        id: vehicle.id,
        name: [vehicle.year, vehicle.make, vehicle.model].compact.join(' ').squish.presence || "Home #{vehicle.id}",
        stock_number: vehicle.stock_number.presence || vehicle.inventory_id,
        model_number: vehicle.catalog_plan_variant&.model_number,
        make: vehicle.make,
        model: vehicle.model,
        series: InventorySettings.series_of(vehicle),
        status: vehicle.status,
        status_label: status_label(vehicle.status),
        hidden_by_switch: @settings.hidden_ids.include?(vehicle.id),
        hidden_by_rule: rule && { field: rule['field'], value: rule['value'] },
        asking_price: asking && { amount: asking[:amount], source: asking[:source], before_surcharge: asking[:before_surcharge] },
        book: book && { book_id: book[:book_id], model_number: book[:model_number] },
        # What the public site sends for this home when prices show.
        public_price: shown_price && { amount: shown_price[:amount], type: shown_price[:type], source: shown_price[:source] },
        featured_sale: featured_sale
      }
    end

    # Ignores the switch: the tab works out "Buyers see" from it and the
    # switch, live. The price list hold still applies (it is not the switch).
    def public_price
      @public_price ||= PublicPrice.new(@company, site: ForcedOn.new(@settings))
    end

    # The settings with the switch on, for "what would a buyer see".
    class ForcedOn < SimpleDelegator
      def show_prices? = true
    end

    def list_price(vehicle)
      inventory_pricing.list_price(vehicle)
    rescue StandardError => e
      Rails.logger.warn("[Websites::InventoryHomes] list price for #{vehicle.id}: #{e.class} #{e.message}")
      nil
    end

    def inventory_pricing
      @inventory_pricing ||= public_price.inventory_pricing
    end

    # This site's Featured Homes picks showing their sale today.
    def featured_sales(vehicles)
      picks = @website.featured_homes.where(vehicle_id: vehicles.map(&:id), show_sale: true).index_by(&:vehicle_id)
      vehicles.each_with_object({}) do |v, out|
        next unless picks[v.id]

        sale = WebsiteFeaturedHome.sale_json(v)
        out[v.id] = sale if sale
      end
    end

    def company_statuses
      raw = @company.public_statuses
      raw = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        [raw]
      end if raw.is_a?(String)
      list = Array(raw).map(&:to_s).reject(&:blank?)
      list.presence || ['available']
    end

    def collect_statuses(node, found)
      case node
      when Hash
        node.each do |key, value|
          if key.to_s == 'statuses'
            found.concat(value.is_a?(String) ? value.split(',') : Array(value).select { |v| v.is_a?(String) })
          else
            collect_statuses(value, found)
          end
        end
      when Array
        node.each { |child| collect_statuses(child, found) }
      end
    end

    def clean(values)
      values.map { |v| v.to_s.squish }.reject(&:blank?).uniq { |v| v.downcase }.sort_by(&:downcase)
    end

    def status_label(status)
      status.to_s.tr('_', ' ').capitalize
    end
  end
end
