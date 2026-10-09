# frozen_string_literal: true

module Truebuild
  # What the agreement's standard sheets say, from one Deal Sheet version:
  # Schedule A (every factory option on the home, with its retail price) and
  # the Color and Finish Selections (every color set offered on the model,
  # with the pick). The price ladder on the contract reads base_price and
  # options_total from here, so the two always agree. Retail only: cost never
  # reaches these sheets.
  class AgreementSheets
    def initialize(build)
      @build = build
    end

    attr_reader :build

    # Schedule A's rows, in sheet order. A color or finish picked at no charge
    # is on the Colors sheet, not here (the PO does the same); one that costs
    # extra is on both. A custom line counts when the rep left it a factory
    # option; lines adopted from Products are fees and services, not options.
    def schedule_rows
      @schedule_rows ||= options.map do |l|
        { 'description' => l.label, 'code' => l.factory_code.presence, 'group' => l.group_name.presence,
          'quantity' => l.quantity.to_d, 'unit' => l.unit, 'status' => status(l), 'price' => l.tbd ? nil : l.retail.to_d,
          'includes' => l.kind == 'option' ? Array(l.option&.package_items).map(&:to_s).reject(&:blank?) : [] }
      end
    end

    def options_total = options.reject(&:tbd).sum { |l| l.retail.to_d }

    # The home before options: the gross less every other priced line, so the
    # rounding step stays on the home as it does on the deal.
    def base_price
      gross = @build.totals.to_h['gross']
      return nil if gross.nil?

      others = @build.lines.select { |l| l.priced? && l.kind != 'base' }
      gross.to_d - others.sum { |l| l.retail.to_d }
    end

    # The Colors sheet's rows, grouped as the price book groups them
    # (Exterior, Interior, Flooring), each set with what was picked.
    def color_rows
      @color_rows ||= begin
        groups = FactoryOrder.offered_sets(@build).transform_values { |opts| opts.first&.group&.name }
        FactoryOrder.colors(@build).map { |c| c.merge('group' => groups[c['set']].presence || 'Other') }
                    .sort_by { |c| [c['group'].downcase, c['set'].to_s.downcase] }
      end
    end

    # What the sheets cannot say yet; the ready-to-send check lists these.
    def open_items
      unpicked = color_rows.select { |c| c['choice'].blank? && !c['skipped'] }.map { |c| c['set'] }
      unpriced = schedule_rows.select { |r| r['price'].nil? }.map { |r| r['description'] }
      items = []
      items << "Colors not chosen: #{unpicked.join(', ')}" if unpicked.any?
      items << "No price yet: #{unpriced.join(', ')}" if unpriced.any?
      items
    end

    def home_name = FactoryOrder.home_name(@build)

    # "28 x 56, 3 bed, 2 bath, 1,493 sq ft"
    def home_size
      v = @build.variant
      size = "#{v.width_ft} x #{v.length_ft}" if v.width_ft && v.length_ft
      baths = v.baths && v.baths.to_d.to_s('F').sub(/\.0\z/, '')
      sq = v.square_feet && v.square_feet.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
      [size, ("#{v.beds} bed" if v.beds), ("#{baths} bath" if baths), ("#{sq} sq ft" if sq)].compact.join(', ')
    end

    private

    def options
      @options ||= begin
        color_ids = FactoryOrder.color_option_ids(@build)
        @build.lines.select do |l|
          next false unless l.kind == 'option' || (l.kind == 'custom' && l.tax_category == 'factory_option')
          next false if l.kind == 'option' && color_ids.include?(l.catalog_option_id) && !l.tbd && l.retail.to_d.zero?

          true
        end
      end
    end

    def status(line)
      return 'Price to follow' if line.tbd
      return 'Standard' if line.is_standard && line.retail.to_d.zero?
      return 'No charge' if line.no_charge || line.retail.to_d.zero?

      'Upgrade'
    end
  end
end
