# frozen_string_literal: true

module Truebuild
  # A dealer's own cost for price book rows (backlog E85): the factory base
  # price or an option's cost, set on their price list or a Deal Sheet line.
  # It prices for them the moment they set it, and the same figure goes to
  # the platform admin as a CatalogPriceRequest to correct the book for every
  # dealer. Their open and dealer_only cost requests ARE the overrides, so a
  # correction applied to the book (or turned down) ends the override with no
  # second record to keep in step.
  #
  # An override belongs to one row of one book: a new factory price book
  # brings new rows, and cost follows the factory again.
  class DealerPrices
    def initialize(company)
      @company = company
    end

    # The dealer's cost for this row, or nil to use the book's.
    def cost_for(row)
      overrides[[row.class.name, row.id]]&.suggested_value
    end

    def request_for(row)
      overrides[[row.class.name, row.id]]
    end

    # A home's base cost from its row: the dealer's base price, if they set
    # one, plus the same required adders the book adds.
    def base_cost(vp)
      own = cost_for(vp)
      return vp.base_cost.to_d unless own

      adders = vp.total_base_price ? vp.total_base_price.to_d - vp.net_base_price.to_d : vp.required_adders.sum { |a| a['amount'].to_d }
      own.to_d + adders
    end

    # Sets (or with a blank value, clears) the dealer's cost for a row and
    # sends it to the platform admin. A figure equal to the book's just
    # clears. Returns the new request, or nil when cleared.
    def self.set!(company:, row:, value:, label:, user: nil, deal: nil, note: nil)
      book_value = row.is_a?(CatalogVariantPrice) ? row.net_base_price : row.dealer_cost
      value = value.presence && BigDecimal(value.to_s.delete(',$'))
      raise ArgumentError, 'A cost cannot be negative' if value&.negative?
      raise ArgumentError, 'A home needs a base price' if value && row.is_a?(CatalogVariantPrice) && value.zero?

      CatalogPriceRequest.transaction do
        live = company.catalog_price_requests.where(target_type: row.class.name, target_id: row.id, field: 'cost')
                      .where(status: CatalogPriceRequest::OVERRIDING)
        live.find_each { |r| r.update!(status: 'withdrawn', resolved_at: Time.current, resolved_by: user) }
        next nil if value.nil? || (book_value && value.round(2) == book_value.to_d.round(2))

        company.catalog_price_requests.create!(
          price_book: row.price_book, target_type: row.class.name, target_id: row.id, field: 'cost',
          current_value: book_value, suggested_value: value, note: note.presence, label: label, deal: deal, requested_by: user
        )
      end
    rescue ArgumentError, TypeError => e
      raise ArgumentError, e.message.start_with?('invalid value') ? "#{value} is not an amount" : e.message
    end

    # The dealer's own selling price for a home (a variant) or an option,
    # on every deal: a company-wide manual markup rule. Blank goes back to
    # their other rules. Retail is the dealer's business, so nothing goes to
    # the platform admin.
    def self.set_retail!(company:, target:, value:)
      scope_type = target.is_a?(CatalogPlanVariant) ? 'variant' : 'option'
      applies_to = scope_type == 'variant' ? 'base' : 'options'
      rule = company.dealer_markup_rules.find_by(location_id: nil, scope_type: scope_type, scope_id: target.id, applies_to: applies_to)
      if value.blank?
        rule&.destroy! if rule&.markup_type == 'manual'
        return nil
      end

      amount = BigDecimal(value.to_s.delete(',$'))
      raise ArgumentError, 'A price must be more than zero' unless amount.positive?

      rule ||= company.dealer_markup_rules.build(location_id: nil, scope_type: scope_type, scope_id: target.id, applies_to: applies_to)
      rule.update!(markup_type: 'manual', value: amount.round(2), active: true, manufacturer_id: target.manufacturer_id)
      rule
    rescue TypeError, ArgumentError => e
      raise ArgumentError, e.message.start_with?('A price') ? e.message : "#{value} is not an amount"
    end

    # The dealer's manual price for a variant or option, if they set one.
    def manual_retail(target)
      type = target.is_a?(CatalogPlanVariant) ? 'variant' : 'option'
      manual_rules[[type, target.id]]&.value
    end

    private

    def manual_rules
      @manual_rules ||= @company.dealer_markup_rules.active.where(location_id: nil, markup_type: 'manual', scope_type: %w[variant option])
                                .index_by { |r| [r.scope_type, r.scope_id] }
    end

    # Oldest first, so a row's latest figure wins the index.
    def overrides
      @overrides ||= @company.catalog_price_requests.overriding.order(:created_at).index_by { |r| [r.target_type, r.target_id] }
    end
  end
end
