# frozen_string_literal: true

# What a commission figure is made of, line by line: which of the deal's lines
# it counts, why the others are left out, and the steps from those lines to the
# figure. The commission worksheet shows this, so a person can see exactly what
# a plan pays on and change the plan if it is not what they meant.
#
# The six fixed figures keep their own math on Deal (front_gross,
# commissionable_front_gross, ...); this explains them with the same line rules
# those methods use, and adds a step for anything the lines do not cover, so
# the steps always land on the figure the engine pays on. The seventh,
# plan_basis ("what this plan pays on"), is figured here from the plan's
# checklist (CommissionPlan#pays_on), so the explanation and the math are one.
class CommissionBasis
  KIND_LABELS = {
    'home' => 'Home', 'freight' => 'Freight charged to the buyer', 'delivery_setup' => 'Delivery, set-up or site work',
    'addon' => 'Add-on or accessory', 'doc_fee' => 'Document fee', 'title_license' => 'Title or license fee',
    'land' => 'Land', 'fi_product' => 'F&I product'
  }.freeze

  # Which pays_on key decides a kind (the home always counts; title and license never do).
  PAYS_ON_KEY = { 'freight' => 'freight', 'delivery_setup' => 'delivery_setup', 'addon' => 'addons',
                  'doc_fee' => 'doc_fee', 'land' => 'land', 'fi_product' => 'fi_products' }.freeze

  SITE_WORDS = /deliver|set ?up|install|skirt|block|site|utilit|septic|\bwell\b|foundation|hook ?up|pier|anchor/i

  def initialize(deal, plan = deal.commission_plan)
    @deal = deal
    @plan = plan
  end

  # The figure, or nil when the deal's cost is not entered.
  def amount(gross_type)
    return plan_basis_amount if gross_type.to_s == 'plan_basis'

    @deal.commission_gross(gross_type)
  end

  # { gross_type:, label:, amount:, rows: [...], steps: [...] }
  # rows: every deal line with { name, kind, kind_label, price, cost, margin, counts, reason }.
  # steps: [{ label:, amount: }] from the counted lines to the figure; the last is the figure.
  def explain(gross_type)
    type = gross_type.to_s
    figure = amount(type)
    rows = lines.map { |l| l.merge(rule(type, l[:kind])) }
    { gross_type: type, label: CommissionComponent.gross_label(type), amount: figure&.to_f,
      cost_entered: !figure.nil?, rows: rows.map { |r| present(r) }, steps: steps(type, rows, figure) }
  end

  # The deal's lines, each sorted into a kind. The home row carries the deal's
  # home price and landed cost (frozen at close), the figures front gross uses.
  def lines
    @lines ||= begin
      home = @deal.home_line_item
      rows = @deal.deal_products.to_a.map do |dp|
        if home && dp.equal?(home)
          price = @deal.front_gross_home_price.to_d
          cost = @deal.landed_cost&.to_d
          { id: dp.id, name: dp.product_name.to_s, kind: 'home', price: price, cost: cost, margin: cost && (price - cost) }
        else
          price = @deal.send(:line_item_price, dp).to_d
          cost = dp.line_cost_total.to_d
          { id: dp.id, name: dp.product_name.to_s, kind: kind_of(dp), price: price, cost: cost, margin: price - cost }
        end
      end
      if home.nil? && @deal.selling_price.present?
        cost = @deal.landed_cost&.to_d
        rows.unshift(id: nil, name: 'Home (deal selling price)', kind: 'home', price: @deal.selling_price.to_d, cost: cost,
                     margin: cost && (@deal.selling_price.to_d - cost))
      end
      rows
    end
  end

  def kind_of(dp)
    category = @deal.send(:extract_line_item_category, dp)
    name = dp.product_name.to_s
    return 'fi_product' if category == 'product'
    return 'title_license' if Deal.title_license_fee_name?(name)
    return 'doc_fee' if Deal.doc_fee_name?(name) && @deal.send(:fee_line_item?, dp)
    return 'freight' if Deal.freight_line_name?(name)
    return 'land' if category == 'land'
    return 'delivery_setup' if category == 'service' || name.match?(SITE_WORDS)

    'addon'
  end

  private

  def pays_on
    @pays_on ||= (@plan || CommissionPlan.new).pays_on
  end

  def trade_difference
    ((@deal.trade_payoff || 0) - (@deal.trade_allowance || 0)).to_d
  end

  def pack
    @deal.effective_pack_amount.to_d
  end

  # Freight the dealer pays rides inside the home's cost on a Deal Sheet deal
  # (Truebuild::DealBuild#write_home_line). A plan that does not take it off
  # adds it back.
  def freight_cost_in_home
    home = @deal.home_line_item
    return BigDecimal('0') unless home&.notes.to_s.include?('deal_sheet:home')

    build = @deal.home_builds.find_by(live: true)
    return BigDecimal('0') unless build

    build.lines.select { |l| l.kind == 'freight' && l.priced? }.sum { |l| l.cost.to_d }
  end

  def plan_basis_amount
    rows = lines
    home = rows.find { |r| r[:kind] == 'home' }
    return nil if home.nil? || home[:margin].nil?

    counted = rows.select { |r| rule('plan_basis', r[:kind])[:counts] }.sum { |r| r[:margin].to_d }
    total = counted - trade_difference
    total += @deal.back_gross.to_d if pays_on['fi_products']
    total += freight_cost_in_home unless pays_on['freight_cost']
    total -= pack if pays_on['pack']
    total.round(2)
  end

  # { counts:, reason: } for a line of this kind under this figure.
  def rule(type, kind)
    return { counts: false, reason: 'Title and license fees are never paid commission' } if kind == 'title_license'

    case type
    when 'front', 'commissionable_front', 'total'
      return { counts: true, reason: 'Counts in front gross' } unless kind == 'fi_product'

      type == 'total' ? { counts: true, reason: 'Counts through F&I product margin (back-end gross)' } : { counts: false, reason: 'F&I belongs to back-end gross' }
    when 'house_profit'
      return { counts: true, reason: 'The plan pays on the home' } if kind == 'home'
      return { counts: false, reason: 'No commission on freight: the plan pays on the home only' } if kind == 'freight'

      { counts: false, reason: 'The plan pays on the home only' }
    when 'addon'
      return { counts: false, reason: 'Add-on commission leaves the home out' } if kind == 'home'
      return { counts: false, reason: 'Add-on commission leaves freight out' } if kind == 'freight'
      return { counts: false, reason: 'Document fees carry no add-on commission' } if kind == 'doc_fee'
      return { counts: false, reason: 'F&I belongs to back-end gross' } if kind == 'fi_product'

      { counts: true, reason: 'Counts at its price (add-on sales)' }
    when 'back'
      kind == 'fi_product' ? { counts: true, reason: 'Counts through F&I product margin' } : { counts: false, reason: 'Back-end gross is F&I only' }
    when 'plan_basis'
      return { counts: true, reason: 'The home always counts' } if kind == 'home'
      return { counts: pays_on['fi_products'], reason: pays_on['fi_products'] ? 'Counts through back-end gross' : 'The plan leaves F&I out' } if kind == 'fi_product'

      key = PAYS_ON_KEY[kind]
      on = pays_on[key]
      { counts: on, reason: on ? 'The plan pays on this' : "The plan leaves #{KIND_LABELS[kind].downcase} out" }
    else
      { counts: false, reason: 'Not part of this figure' }
    end
  end

  def steps(type, rows, figure)
    return [] if figure.nil?

    out = []
    line_rows = rows.reject { |r| r[:kind] == 'fi_product' && %w[total back plan_basis].include?(type) }
    counted = line_rows.select { |r| r[:counts] }
    if type == 'addon'
      out << { label: 'Add-on sales counted (price)', amount: counted.sum { |r| r[:price].to_d } }
    elsif type != 'back'
      out << { label: 'Margin on the lines that count', amount: counted.sum { |r| r[:margin].to_d } }
      out << { label: 'less trade-in over allowance', amount: -trade_difference } unless trade_difference.zero?
    end
    if %w[back total].include?(type) || (type == 'plan_basis' && pays_on['fi_products'])
      out << { label: 'Finance reserve', amount: @deal.finance_reserve.to_d } unless @deal.finance_reserve.to_d.zero?
      out << { label: 'F&I product margin', amount: @deal.product_margin.to_d } unless @deal.product_margin.to_d.zero?
    end
    if type == 'plan_basis' && !pays_on['freight_cost'] && freight_cost_in_home.positive?
      out << { label: 'Freight you pay, not taken off', amount: freight_cost_in_home }
    end
    takes_pack = %w[commissionable_front house_profit].include?(type) || (type == 'plan_basis' && pays_on['pack'])
    out << { label: 'less dealer pack', amount: -pack } if takes_pack && !pack.zero?

    explained = out.sum { |s| s[:amount].to_d }.round(2)
    other = (figure.to_d - explained).round(2)
    out << { label: 'Other deal figures (not on a line)', amount: other } unless other.zero?
    out << { label: "= #{CommissionComponent.gross_label(type).sub(/\A./, &:upcase)}", amount: figure.to_d, total: true }
    out.map { |s| s.merge(amount: s[:amount].to_d.round(2).to_f) }
  end

  def present(row)
    { id: row[:id], name: row[:name], kind: row[:kind], kind_label: KIND_LABELS[row[:kind]],
      price: row[:price]&.to_f, cost: row[:cost]&.to_f, margin: row[:margin]&.to_f,
      counts: row[:counts], reason: row[:reason] }
  end
end
