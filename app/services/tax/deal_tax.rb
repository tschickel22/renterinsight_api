# frozen_string_literal: true

module Tax
  # Sales tax on a home sale, by the rules of the state that taxes it
  # (backlog E45, fixes B28). Used by the deal sheet and by GL posting, so the
  # tax a buyer is quoted is the tax that posts.
  #
  # A state's rules: what percent of the price is taxed, who pays (the dealer
  # collects it from the buyer, the dealer owes use tax on its own cost, or
  # the buyer pays when the home is titled), whether a trade-in reduces the
  # base, whether a pre-owned home is exempt, and the wording agreements
  # print. Defaults below; a dealer overrides any of them per state in
  # Accounting settings (tax_rates_by_state[state]['rules']).
  class DealTax
    PAYERS = %w[dealer_collects dealer_use_tax buyer_at_titling].freeze

    # Any state not listed: today's behavior, the whole price at the combined
    # rate, collected by the dealer, trade not deducted.
    DEFAULT_RULES = {
      'taxable_pct' => 100, 'payer' => 'dealer_collects', 'trade_reduces' => false, 'used_exempt' => false,
      'use_tax_rate' => nil, 'use_tax_includes_freight' => true, 'disclosure' => nil
    }.freeze

    # From Factory Direct's own quote desk (2026). Not tax advice: a dealer
    # confirms these with their accountant, and can change any of them.
    STATE_RULES = {
      'IN' => { 'taxable_pct' => 65, 'trade_reduces' => true, 'used_exempt' => true, 'state_rate' => 7.0,
                'disclosure' => 'Per IC 6-2.5-5-29 and DOR Bulletin #65. The selling price includes delivery, set-up and ' \
                                'utility connections sold by the dealer.' },
      'OH' => { 'payer' => 'dealer_use_tax', 'use_tax_rate' => 7.25, 'disclosure' => nil },
      'MI' => { 'payer' => 'buyer_at_titling', 'state_rate' => 6.0, 'disclosure' => nil }
    }.freeze

    def self.state_code(value)
      Truebuild::DealerFactories.state(value).presence
    end

    # The dealer delivers: the homesite's state. The buyer picks up at the
    # lot: the lot's state.
    def self.taxing_state(deal)
      raw = if deal.try(:delivery_point) == 'lot'
              deal.location&.state.presence || deal.company&.state
            else
              deal.delivery_state.presence || deal.try(:billing_state).presence || deal.location&.state.presence
            end
      state_code(raw)
    end

    # These rules are for selling a manufactured home. A deal for a part, an
    # installation or anything else (and every invoice) is taxed the usual way.
    def self.home_sale?(deal)
      return false unless deal.company&.industry.to_s == 'manufactured_housing'

      deal.try(:home_build).present? || deal.try(:home_line_item).present?
    end

    def self.rules_for(company, state, home_sale: true)
      return DEFAULT_RULES unless home_sale

      settings = AccountingSettings.for_company(company)
      custom = (settings.tax_rates_by_state || {}).dig(state.to_s, 'rules') || {}
      DEFAULT_RULES.merge(STATE_RULES.fetch(state.to_s, {})).merge(custom.stringify_keys.compact)
    end

    # selling_price: after discounts. trade: the trade-in allowance.
    # cost_basis / freight_cost: the dealer's cost, for use-tax states.
    # home_sale: nil works it out from the deal (self.home_sale?).
    def initialize(deal:, selling_price:, trade: 0, cost_basis: 0, freight_cost: 0, used: false, home_sale: nil)
      @deal = deal
      @home_sale = home_sale.nil? ? self.class.home_sale?(deal) : home_sale
      @price = selling_price.to_d
      @trade = trade.to_d
      @cost_basis = cost_basis.to_d
      @freight_cost = freight_cost.to_d
      @used = used
    end

    def call
      state = self.class.taxing_state(@deal)
      return blank(state, 'No delivery state yet: choose where the home goes to work out tax.') unless state

      rules = self.class.rules_for(@deal.company, state, home_sale: @home_sale)
      settings = AccountingSettings.for_company(@deal.company)
      rates = settings.combined_tax_rate(state)
      note = nil
      # No rate set up for this state yet: its standard state rate, said so.
      if rates[:combined].to_d.zero? && rules['state_rate']
        r = rules['state_rate'].to_d
        rates = { state: r, county: 0.to_d, city: 0.to_d, combined: r }
        note = "Using #{state}'s #{r.to_s('F').sub(/\.0\z/, '')}% state rate. Set your rates in Accounting settings, Sales tax."
      end
      rate = rates[:combined].to_d
      after_trade = [@price - @trade, 0].max
      base = rules['trade_reduces'] ? after_trade : @price
      base = (base * rules['taxable_pct'].to_d / 100).round(2)
      exempt = @used && rules['used_exempt']
      base = 0.to_d if exempt
      tax = (base * rate / 100).round(2)

      use_basis = @cost_basis + (rules['use_tax_includes_freight'] ? @freight_cost : 0)
      use_tax = rules['payer'] == 'dealer_use_tax' ? (use_basis * rules['use_tax_rate'].to_d / 100).round(2) : 0.to_d
      collected = rules['payer'] == 'dealer_collects' ? tax : 0.to_d
      {
        state: state, rules: rules, payer: rules['payer'], exempt: exempt,
        rates: rates.transform_values(&:to_f), rate: rate.to_f,
        base: base.to_f, collected: collected.to_f, at_titling: (rules['payer'] == 'buyer_at_titling' ? tax : 0).to_f,
        use_tax: use_tax.to_f, after_trade: after_trade.to_f,
        effective_pct: @price.positive? ? (collected / @price * 100).round(2).to_f : 0.0,
        slots: %i[state county city].to_h { |k| [k, rules['payer'] == 'dealer_collects' ? (base * rates[k].to_d / 100).round(2).to_f : 0.0] },
        taxable_pct: rules['taxable_pct'].to_f, trade_reduces: rules['trade_reduces'], home_sale: @home_sale,
        disclosure: explain(state, rules, rate, exempt), note: note
      }
    end

    # The tax treatment in a sentence, the way Factory Direct's sheet prints it:
    # "Tax on 65% of the selling price after trade-in at 7%. Per IC 6-2.5-5-29..."
    def explain(state, rules, rate, exempt)
      pct = number(rules['taxable_pct'])
      sentence =
        case rules['payer']
        when 'dealer_use_tax'
          "The dealer pays #{number(rules['use_tax_rate'])}% #{state} use tax on its cost" \
            "#{rules['use_tax_includes_freight'] ? ', freight included' : ''}. No sales tax is charged to the buyer."
        when 'buyer_at_titling'
          "The buyer pays #{state} tax of #{number(rate)}% when the home is titled. It is not collected here."
        else
          exempt ? "A pre-owned home is exempt from #{state} sales tax." :
            "Tax on #{pct}% of the selling price#{rules['trade_reduces'] ? ' after trade-in' : ''} at #{number(rate)}%."
        end
      [sentence, rules['disclosure'].presence].compact.join(' ')
    end

    def number(value)
      d = value.to_d
      d.frac.zero? ? d.to_i.to_s : d.round(3).to_s('F')
    end

    private

    def blank(state, note)
      { state: state, rules: DEFAULT_RULES, payer: nil, exempt: false, rates: {}, rate: 0.0, base: 0.0, collected: 0.0,
        at_titling: 0.0, use_tax: 0.0, after_trade: [@price - @trade, 0].max.to_f, effective_pct: 0.0,
        slots: { state: 0.0, county: 0.0, city: 0.0 }, taxable_pct: 100.0, trade_reduces: false, home_sale: @home_sale,
        disclosure: nil, note: note }
    end
  end
end
