# frozen_string_literal: true

module Truebuild
  # What the agreement's standard sheets say, from one Deal Sheet version:
  # Schedule A (every factory option on the home, with its retail price) and
  # the Color and Finish Selections (every color set offered on the model,
  # with the pick). The price ladder on the contract reads base_price and
  # options_total from here, so the two always agree. Retail only: cost never
  # reaches these sheets.
  class AgreementSheets
    # A color or finish picked at no charge. It is a selection, not an upgrade:
    # it fills the Colors sheet and the color references, and stays off Addendum A.
    def self.free_color?(line)
      line.kind == 'option' && line.option.present? && DealBuild.choice_set(line.option).present? &&
        !line.tbd && line.retail.to_d.zero?
    end

    def self.color_key(set) = "color.#{set.to_s.parameterize(separator: '_')}"

    def initialize(build)
      @build = build
    end

    attr_reader :build

    # Schedule A's rows, in sheet order. A color or finish picked at no charge
    # is on the Colors sheet, not here (the PO does the same); one that costs
    # extra is on both. A line the rep typed and ticked for Addendum A is an
    # option by then (DealBuild#set_addendum), kept on their list for next time;
    # lines adopted from Products are fees and services, not options.
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

    # The picks as references a contract can name: color.siding => "Clay". A
    # shingle set goes by several names in the books ("3 Tab Shingles"), so it
    # also answers to color.shingles.
    def color_values
      @color_values ||= color_rows.each_with_object({}) do |c, out|
        next if c['choice'].blank?

        out[self.class.color_key(c['set'])] = c['choice']
        out['color.shingles'] ||= c['choice'] if c['set'].to_s.match?(/shingle/i)
      end
    end

    # The general "exterior color" and "interior color" a contract can ask for.
    def exterior_color = first_pick('Siding', 'Exterior', 'Body')
    def interior_color = first_pick('Main panel', 'Interior walls', 'Interior', 'Walls')

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
      v = @build.specs
      size = "#{v['width_ft']} x #{v['length_ft']}" if v['width_ft'] && v['length_ft']
      baths = v['baths'] && v['baths'].to_d.to_s('F').sub(/\.0\z/, '')
      sq = v['square_feet'] && v['square_feet'].to_s.reverse.scan(/\d{1,3}/).join(',').reverse
      [size, ("#{v['beds']} bed" if v['beds']), ("#{baths} bath" if baths), ("#{sq} sq ft" if sq)].compact.join(', ')
    end

    private

    def options
      @options ||= @build.lines.select do |l|
        (l.kind == 'option' || (l.kind == 'custom' && l.tax_category == 'factory_option')) && !self.class.free_color?(l)
      end
    end

    def first_pick(*sets)
      sets.filter_map { |set| color_values[self.class.color_key(set)] }.first
    end

    def status(line)
      return 'Price to follow' if line.tbd
      return 'Standard' if line.is_standard && line.retail.to_d.zero?
      return 'No charge' if line.no_charge || line.retail.to_d.zero?

      'Upgrade'
    end
  end
end
