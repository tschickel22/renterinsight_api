# frozen_string_literal: true

# Shows what a commission plan would pay before anyone relies on it, on a real
# deal or a sample one. Everything runs on the commission engine against deals held
# in memory: nothing here is saved, and a plan does not have to be active.
class CommissionPlanTester
  SALESPERSON = -1
  SAMPLE_PEOPLE = { secondary_salesperson: -2, sales_manager: -3, finance_manager: -4, desk_manager: -5 }.freeze

  ROLE_LABELS = {
    primary_salesperson: 'Salesperson', secondary_salesperson: 'Second salesperson', sales_manager: 'Sales manager',
    finance_manager: 'Finance manager', desk_manager: 'Desk manager'
  }.freeze

  SAMPLES = [
    { key: 'single', name: 'Single section home', home_price: 85_000, home_cost: 55_000, addon_price: 8_000, addon_cost: 5_000, pack: 0 },
    { key: 'double', name: 'Double section with site work', home_price: 165_000, home_cost: 120_000, addon_price: 25_000, addon_cost: 15_000, pack: 0 },
    { key: 'thin', name: 'Low margin home', home_price: 62_000, home_cost: 58_500, addon_price: 3_000, addon_cost: 2_000, pack: 0 }
  ].freeze

  # A deal that exists only in memory, with stand-ins in the positions asked for.
  def self.sample_deal(plan, figures, roles = [])
    deal = Deal.new(company: plan.company, name: 'Sample deal', stage: 'proposal', commission_plan: plan, quantity: 1,
                    selling_price: figures[:home_price], unit_cost: figures[:home_cost], pack_amount: figures[:pack].to_d,
                    primary_salesperson_id: SALESPERSON)
    add_line(deal, 'Home', figures[:home_price], figures[:home_cost], 'category:home')
    if figures[:addon_price].to_d.nonzero? || figures[:addon_cost].to_d.nonzero?
      add_line(deal, 'Delivery and site work', figures[:addon_price], figures[:addon_cost], 'category:service')
    end
    roles.each { |role| deal.public_send("#{CommissionPaymentGeneratorService::ROLE_FIELDS.fetch(role)}=", SAMPLE_PEOPLE.fetch(role)) }
    deal.readonly!
    deal
  end

  def self.add_line(deal, name, price, cost, notes)
    deal.deal_products.build(product_name: name, unit_price: price.to_d, cost: cost.to_d, quantity: 1, total: price.to_d, notes: notes)
  end
  private_class_method :add_line

  def self.sample_result(plan, figures, roles)
    deal = sample_deal(plan, figures, roles)
    engine = CommissionPaymentGeneratorService.new(deal)
    payouts = []
    not_paid = []
    ([:primary_salesperson] + roles).each do |role|
      lines = engine.lines_for_role(role)
      next not_paid << { role: role.to_s, label: ROLE_LABELS[role], person: nil } if lines.empty?

      payouts << { role: role.to_s, label: ROLE_LABELS[role], person: nil, amount: lines.sum(BigDecimal('0')) { |l| l[:amount] }.round(2).to_f,
                   lines: lines.map { |l| { name: l[:component].name, amount: l[:amount].to_f, note: l[:note] }.compact } }
    end
    result(deal, payouts, not_paid)
  end

  # A real deal priced on this plan. The deal is read only and its plan is swapped in memory.
  def self.deal_result(plan, deal)
    deal.readonly!
    deal.commission_plan = plan
    preview = CommissionPaymentGeneratorService.preview_for_deal(deal)
    payouts = preview[:participants].map do |p|
      { role: p[:role], label: ROLE_LABELS[p[:role].to_sym], person: p[:user_name], amount: p[:estimated_amount],
        lines: p[:components].map { |c| { name: c[:name], amount: c[:amount], note: c[:note] }.compact } }
    end
    not_paid = preview[:unpaid_positions].map { |p| { role: p[:role], label: ROLE_LABELS[p[:role].to_sym], person: p[:user_name] } }
    result(deal, payouts, not_paid)
  end

  def self.result(deal, payouts, not_paid)
    total = payouts.sum { |p| p[:amount].to_d }.round(2)
    front = deal.front_gross
    {
      costEntered: deal.cost_entered?,
      figures: {
        homePrice: deal.front_gross_home_price.to_f, homeCost: deal.landed_cost&.to_f, addonProfit: deal.front_end_addon_margin.to_f,
        pack: deal.effective_pack_amount.to_f, houseProfit: deal.house_profit&.to_f, commissionableFront: deal.commissionable_front_gross&.to_f
      },
      payouts: payouts,
      notPaid: not_paid,
      total: total.to_f,
      dealershipKeeps: front && (front.to_d - total).round(2).to_f
    }
  end
  private_class_method :result
end
