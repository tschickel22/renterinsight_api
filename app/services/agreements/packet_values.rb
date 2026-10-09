# frozen_string_literal: true

module Agreements
  # Everything an agreement packet can fill in, as one flat set of named
  # values from the deal, its LIVE Deal Sheet and its sale details. A dealer's
  # contract maps its blanks to these names (the packet's "fills"), so a new
  # dealer's contract needs a mapping, not code. Prices are retail, from the
  # same figures as Schedule A; cost is never here.
  class PacketValues
    STATE_NAMES = { 'IN' => 'Indiana', 'OH' => 'Ohio', 'MI' => 'Michigan', 'IL' => 'Illinois', 'KY' => 'Kentucky' }.freeze

    attr_reader :build, :sheets

    def initialize(deal, agreement_number: nil, date: Date.current)
      @deal = deal
      @build = deal.home_build
      @sheets = @build && Truebuild::AgreementSheets.new(@build)
      @details = DealSaleDetails.new(deal)
      @agreement_number = agreement_number
      @date = date
    end

    def [](key) = to_h[key.to_s]

    def to_h
      @to_h ||= agreement.merge(buyers).merge(site).merge(home).merge(prices).merge(sale).compact_blank
    end

    def self.date(value)
      value.is_a?(String) ? (Date.iso8601(value) rescue nil)&.strftime('%m/%d/%Y') : value&.strftime('%m/%d/%Y')
    end

    def self.money(value)
      return nil if value.nil?

      whole, decimal = format('%.2f', value.to_f.abs).split('.')
      "#{'-' if value.to_f.round(2).negative?}$#{whole.reverse.scan(/\d{1,3}/).join(',').reverse}.#{decimal}"
    end

    private

    def filled = @filled ||= @details.filled
    def values = @values ||= @details.values

    def agreement
      finance = @details.finance?
      cash = @details.cash?
      { 'agreement.number' => @agreement_number || @deal.deal_number, 'agreement.date' => self.class.date(@date),
        'deal.number' => @deal.deal_number,
        'deal.type' => (finance ? 'FINANCE' : ('CASH' if cash)),
        'deal.finance_applies' => (finance ? 'YES' : ('NO' if cash)), 'deal.cash_applies' => (cash ? 'YES' : ('NO' if finance)),
        'deal.delivery_point' => (@deal.try(:delivery_point) == 'lot' ? 'BUYER TAKES DELIVERY' : 'DEALER DELIVERS'),
        'rep.name' => @deal.owner&.full_name }
    end

    def buyers
      out = {}
      [[filled[:buyer_1], @deal.contact], [filled[:buyer_2], @deal.co_applicant_contact]].each_with_index do |(b, contact), i|
        next unless b

        n = "buyer_#{i + 1}"
        out.merge!("#{n}.name" => b[:name], "#{n}.phone" => b[:phone], "#{n}.email" => b[:email], "#{n}.address" => b[:address],
                   "#{n}.street" => contact.street, "#{n}.city" => contact.city, "#{n}.state" => contact.state, "#{n}.zip" => contact.zip)
      end
      out['buyers.names'] = [out['buyer_1.name'], out['buyer_2.name']].compact.join(' and ')
      out
    end

    def site
      d = filled[:delivery]
      state = d[:state].to_s.strip
      { 'site.street' => d[:street], 'site.city' => d[:city], 'site.state' => state, 'site.zip' => d[:zip],
        'site.state_name' => STATE_NAMES[state.upcase] || state.presence, 'site.county' => values['county'],
        'site.ownership' => values['site_ownership'], 'site.community' => values['community_name'],
        'site.lot' => values['lot_number'], 'site.landlord' => values['landlord'] }
    end

    def home
      return { 'home.serial' => filled[:serial_number] } unless @build

      v = @build.variant
      used = @build.vehicle&.condition.to_s.casecmp?('used')
      { 'home.manufacturer' => v.manufacturer&.name, 'home.factory' => v.catalog_plan&.factory&.name || @build.price_book&.factory&.name,
        'home.condition' => used ? 'PRE-OWNED' : 'NEW',
        'home.description' => [v.manufacturer&.name, v.catalog_plan&.series, v.catalog_plan&.name, v.model_number].compact.uniq.join(' ').squish,
        'home.name' => @sheets.home_name, 'home.model_number' => v.model_number, 'home.size' => @sheets.home_size,
        'home.model_year' => values['model_year'], 'home.serial' => filled[:serial_number], 'home.hud_labels' => values['hud_labels'],
        'home.floor_size' => ("#{v.width_ft} x #{v.length_ft}" if v.width_ft && v.length_ft), 'home.square_feet' => v.square_feet&.to_s,
        'home.beds' => v.beds&.to_s, 'home.baths' => v.baths && v.baths.to_d.to_s('F').sub(/\.0\z/, '') }
    end

    # Page 1's price ladder: base, options, freight, set-up, utilities, fees,
    # other; the discounts; selling price, trade, tax, total and balance.
    def prices
      return {} unless @build

      t = @build.totals.to_h
      lines = @build.lines.select(&:priced?)
      sum = ->(set) { set.sum { |l| l.retail.to_d } }
      freight = lines.select { |l| l.kind == 'freight' }
      setup = lines.select { |l| l.kind != 'freight' && l.tax_category == 'setup' }
      utility = lines.select { |l| l.tax_category == 'utility_connection' }
      fees = lines.select { |l| l.tax_category == 'fee' }
      counted = [freight, setup, utility, fees].flatten
      other = lines.reject { |l| %w[base option].include?(l.kind) || counted.include?(l) ||
                                  (l.kind == 'custom' && l.tax_category == 'factory_option') }
      other_total = sum.call(other) + t['other_lines_total'].to_d
      discounts = t['discounts'].to_h
      tax = t['tax'].to_h
      m = ->(x) { self.class.money(x) }
      { 'price.base' => m.(@sheets.base_price), 'price.options' => m.(@sheets.options_total),
        'price.freight' => m.(sum.call(freight)), 'price.setup' => m.(sum.call(setup)), 'price.utilities' => m.(sum.call(utility)),
        'price.doc_fee' => m.(sum.call(fees)), 'price.other' => m.(other_total),
        'price.other_label' => other.map(&:label).join(', ').presence,
        'price.gross' => m.(t['gross'] && t['gross'].to_d + t['other_lines_total'].to_d),
        'price.discount_savings' => m.(discounts['savings']), 'price.discount_sale' => m.(discounts['sale']),
        'price.discount_preferred' => m.(discounts['preferred']),
        'price.discount_preferred_pct' => @build.discounts.to_h['preferred_pct'].to_d.positive? ? @build.discounts.to_h['preferred_pct'].to_d.to_s('F').sub(/\.0\z/, '') : nil,
        'price.discount_other' => m.(discounts['other']),
        'price.selling' => m.(t['retail']), 'price.trade' => m.(t['trade_allowance']),
        'price.after_trade' => m.(t['retail'] && [t['retail'].to_d - t['trade_allowance'].to_d, 0].max),
        'tax.base' => m.(tax['base']), 'tax.collected' => m.(tax['collected']), 'tax.state' => tax['state'],
        'tax.state_name' => STATE_NAMES[tax['state'].to_s.upcase] || tax['state'],
        'price.contract_total' => m.(t['contract_total']), 'price.down_payment' => m.(t['down_payment']),
        'price.additional_payment' => m.(t['additional_payment']), 'price.unpaid' => m.(t['unpaid_balance']) }
    end

    def sale
      d = ->(k) { self.class.date(values[k]) }
      { 'sale.contingency' => values['contingency'], 'sale.contingency_deadline' => d.('contingency_deadline'),
        'sale.contingency_description' => values['contingency_description'], 'sale.estimated_completion' => d.('estimated_completion'),
        'sale.loan_type' => values['loan_type'], 'sale.loan_officer' => values['loan_officer'], 'sale.land_status' => values['land_status'],
        'sale.approval_date' => d.('approval_date'), 'sale.approval_expires' => d.('approval_expires'),
        'sale.lender' => filled[:lender_name], 'sale.payment_method' => values['payment_method'],
        'sale.lienholder' => (@details.finance? ? filled[:lender_name] : ('None' if @details.cash?)),
        'sale.deposit_received_on' => d.('deposit_received_on'), 'sale.balance_due_by' => d.('balance_due_by'),
        'sale.down_payment_due' => self.class.date(filled[:down_payment_due_date]),
        'sale.expected_delivery' => self.class.date(filled[:expected_delivery]) }
    end
  end
end
