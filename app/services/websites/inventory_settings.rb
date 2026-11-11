# frozen_string_literal: true

module Websites
  # A website's own inventory choices (Edit Website, Inventory tab, 2026-11-11):
  #
  #   show_prices         one switch for every inventory section, the home
  #                       page and the TrueBuild design page on this site.
  #                       Homes on sale in Featured Homes with "Display sale
  #                       pricing on website" on still show their sale.
  #   hide_rules          [{ field: make|series|model|status, value: }]
  #   hidden_vehicle_ids  single homes switched off for this site
  #   price_list_held     set only for a site that existed before the switch
  #                       and showed prices while its TrueBuild prices were
  #                       hidden (or monthly only): price list (marked-up)
  #                       prices and the TrueBuild design page keep following
  #                       the dealer's TrueBuild "What buyers see", as before,
  #                       until the dealer saves the switch or presses
  #                       "Show them too" on the tab.
  #
  # Stored on websites.inventory_settings (jsonb). A hidden home stays in
  # inventory; it is only left out of this site's public inventory answers.
  #
  # A site saved before the setting existed has no show_prices key: it shows
  # what its sections showed (#legacy_show_prices), so nothing a live site
  # shows changes until a dealer flips the switch.
  class InventorySettings
    RULE_FIELDS = %w[make series model status].freeze
    MAX_RULES = 100
    MAX_HIDDEN = 5000
    INVENTORY_BLOCKS = %w[inventory].freeze
    FEATURED_BLOCKS = %w[featuredHomes featured_homes].freeze

    # The settings for the site a public request names, or nil (an embed or
    # an external page: no site, so the company-wide behavior applies).
    def self.for_request(company, website_id)
      return nil if company.nil? || website_id.blank?

      website = company.websites.where(is_deleted: [false, nil]).find_by(id: website_id.to_i)
      website && new(website)
    end

    # Cleans what the editor sends. Unknown fields and blank values drop out;
    # values keep the dealer's spelling (matching ignores case and spaces).
    def self.normalize(raw, company: nil)
      raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
      raw = raw.deep_stringify_keys
      out = {}
      out['show_prices'] = ActiveModel::Type::Boolean.new.cast(raw['show_prices']) == true if raw.key?('show_prices')

      rules = Array(raw['hide_rules']).filter_map do |rule|
        rule = rule.respond_to?(:to_unsafe_h) ? rule.to_unsafe_h : rule
        next unless rule.is_a?(Hash)

        field = rule['field'].to_s
        value = rule['value'].to_s.squish
        next unless RULE_FIELDS.include?(field) && value.present?

        { 'field' => field, 'value' => value.first(120) }
      end
      out['hide_rules'] = rules.uniq { |r| [r['field'], r['value'].downcase] }.first(MAX_RULES)

      ids = Array(raw['hidden_vehicle_ids']).map(&:to_i).select(&:positive?).uniq
      # CRITICAL: only this company's homes.
      ids = company.vehicles.where(id: ids).pluck(:id) if company && ids.any?
      out['hidden_vehicle_ids'] = ids.sort.first(MAX_HIDDEN)
      out
    end

    # What a site showed before the setting existed, worked out from its
    # sections: an Inventory section showed prices unless its own "Show
    # pricing on cards" was off (unset followed the company's Show pricing);
    # a Featured Homes section only when its "Show price" was on. A site
    # with neither follows the company.
    def self.legacy_show_prices(website)
      company_on = website.company.try(:show_pricing) != false
      inventory, featured = legacy_blocks(website)

      if inventory.any?
        inventory.any? do |content|
          own = content.key?('show_pricing') ? content['show_pricing'] : content['showPricing']
          own.nil? ? company_on : own != false
        end
      elsif featured.any?
        featured.any? { |content| content['showPricing'] == true }
      else
        company_on
      end
    end

    # A site whose Featured Homes cards showed no price ("Show price" was
    # off by default) while the site showed prices elsewhere.
    def self.legacy_featured_held(website)
      _inventory, featured = legacy_blocks(website)
      featured.any? && featured.none? { |content| content['showPricing'] == true }
    end

    def self.legacy_blocks(website)
      inventory = []
      featured = []
      website.website_pages.where(is_deleted: [false, nil]).pluck(:blocks).each { |b| collect_blocks(b, inventory, featured) }
      [inventory, featured]
    end

    def self.collect_blocks(node, inventory, featured)
      case node
      when Array
        node.each { |child| collect_blocks(child, inventory, featured) }
      when Hash
        type = node['type'].to_s
        content = node['content'].is_a?(Hash) ? node['content'] : node
        inventory << content if INVENTORY_BLOCKS.include?(type)
        featured << content if FEATURED_BLOCKS.include?(type)
        node.each_value { |child| collect_blocks(child, inventory, featured) if child.is_a?(Array) || child.is_a?(Hash) }
      end
    end

    attr_reader :website

    def initialize(website)
      @website = website
      @raw = (website.try(:inventory_settings) || {}).to_h.deep_stringify_keys
    end

    def show_prices?
      return @show_prices if defined?(@show_prices)

      @show_prices = @raw.key?('show_prices') ? @raw['show_prices'] == true : self.class.legacy_show_prices(@website)
    end

    # Price list prices and the design page's prices held back (see above).
    # Only matters while show_prices is on.
    def price_list_held?
      return @price_list_held if defined?(@price_list_held)

      @price_list_held = if @raw.key?('show_prices')
                           @raw['price_list_held'] == true
                         else
                           self.class.legacy_price_list_held(@website.company)
                         end
    end

    # Featured Homes cards keep showing no price, as before the switch (a
    # Featured Homes sale the dealer turned on still shows). Only matters
    # while show_prices is on.
    def featured_price_held?
      return @featured_price_held if defined?(@featured_price_held)

      @featured_price_held = if @raw.key?('show_prices')
                               @raw['featured_price_held'] == true
                             else
                               self.class.legacy_featured_held(@website)
                             end
    end

    # Anything still shown the old way while the switch is on.
    def held?
      show_prices? && (price_list_held? || featured_price_held?)
    end

    # For the TrueBuild design page: true shows prices, false hides them, nil
    # leaves it to the dealer's TrueBuild "What buyers see" (a held site).
    def designer_prices
      return false unless show_prices?

      price_list_held? ? nil : true
    end

    # Before the switch, price list prices reached a site only when the
    # company showed pricing and TrueBuild prices were not hidden
    # (InventoryPricing#public_prices_shown?), and the design page showed
    # prices only for "What buyers see" full or starting at. Held when that
    # differs from what the switch alone would show.
    def self.legacy_price_list_held(company)
      return true if company.nil?

      company.try(:show_pricing) == false ||
        !Truebuild::BuyerCatalog::SHOWS_PRICES.include?(DealerCatalogTerm.effective(company, nil).price_display)
    end

    def rules
      @rules ||= self.class.normalize({ 'hide_rules' => @raw['hide_rules'] })['hide_rules']
    end

    def hidden_ids
      @hidden_ids ||= Array(@raw['hidden_vehicle_ids']).map(&:to_i).select(&:positive?).uniq
    end

    def to_h
      { show_prices: show_prices?, price_list_held: show_prices? && price_list_held?,
        featured_price_held: show_prices? && featured_price_held?,
        hide_rules: rules.map(&:symbolize_keys), hidden_vehicle_ids: hidden_ids }
    end

    # What a public page needs: only the switch (and whether Featured Homes
    # cards still hide their price, see #featured_price_held?).
    def public_h
      { show_prices: show_prices?, featured_price_held: show_prices? && featured_price_held? }
    end

    # The homes this site may show, out of a vehicles scope.
    def visible(scope)
      scope = scope.where.not(id: hidden_ids) if hidden_ids.any?
      rules.group_by { |r| r['field'] }.each do |field, list|
        values = list.map { |r| r['value'].downcase }
        scope = scope.where("#{self.class.field_sql(field)} NOT IN (?)", values)
      end
      scope
    end

    def hidden?(vehicle)
      hidden_ids.include?(vehicle.id) || rule_for(vehicle).present?
    end

    # The first rule that hides this home, or nil.
    def rule_for(vehicle)
      values = self.class.rule_values(vehicle)
      rules.find { |r| values[r['field']] == r['value'].downcase }
    end

    # A home's values for each rule field, lowercased and trimmed, the way
    # #field_sql reads them.
    def self.rule_values(vehicle)
      {
        'make' => vehicle.make.to_s.strip.downcase,
        'model' => vehicle.model.to_s.strip.downcase,
        'status' => vehicle.status.to_s.strip.downcase,
        'series' => series_of(vehicle).to_s.strip.downcase
      }
    end

    # The feed's series name, else the linked price list model's series.
    def self.series_of(vehicle)
      vehicle.try(:champion_series_name).presence || vehicle.catalog_plan_variant&.catalog_plan&.series
    end

    SERIES_SQL = <<~SQL.squish.freeze
      COALESCE(NULLIF(vehicles.champion_series_name, ''),
               (SELECT catalog_plans.series FROM catalog_plan_variants
                  JOIN catalog_plans ON catalog_plans.id = catalog_plan_variants.catalog_plan_id
                 WHERE catalog_plan_variants.id = vehicles.catalog_plan_variant_id), '')
    SQL

    def self.field_sql(field)
      case field
      when 'make' then "LOWER(TRIM(COALESCE(vehicles.make, '')))"
      when 'model' then "LOWER(TRIM(COALESCE(vehicles.model, '')))"
      when 'status' then "LOWER(TRIM(COALESCE(vehicles.status, '')))"
      when 'series' then "LOWER(TRIM(#{SERIES_SQL}))"
      else raise ArgumentError, "unknown rule field #{field}"
      end
    end
  end
end
