# frozen_string_literal: true

# Explains a commission plan in plain words: the setup steps left, what it pays on a
# sample deal (worked out by the commission engine), and the setups that usually
# do not do what the dealer meant.
class CommissionPlanGuide
  SAMPLE_PROFIT = 30_000
  SAMPLE = { home_price: 100_000, home_cost: 70_000, addon_price: 0, addon_cost: 0, pack: 0 }.freeze
  PROFIT_NAMES = {
    'house_profit' => 'house profit', 'commissionable_front' => 'commissionable front gross', 'front' => 'front gross', 'total' => 'total gross'
  }.freeze
  OTHER_BASES = { 'back' => 'back gross', 'addon' => 'add-on gross', 'selling_price' => 'the selling price' }.freeze
  PERCENT_TYPES = %w[percent_of_gross percentage].freeze

  def initialize(plan)
    @plan = plan
    @components = plan.commission_components.where(is_active: true).ordered.to_a
  end

  def as_json(*)
    { checklist: checklist, summary: summary, warnings: warnings }
  end

  private

  def percents
    @components.select { |c| c.component_type.in?(PERCENT_TYPES) }
  end

  def fee_ids
    @plan.fee_component_ids & @components.map(&:id)
  end

  def fees?
    @plan.company_fee_percent.positive? || fee_ids.any?
  end

  def role_of(component)
    (component.applies_to_role.presence || 'primary_salesperson').to_sym
  end

  def checklist
    [
      { key: 'people', label: 'Add who gets paid', done: @components.any? },
      { key: 'profit', label: 'Choose the profit each percent pays on', done: @components.any? && percents.all? { |c| c.gross_type.present? } },
      { key: 'fees', label: 'Set any fees that come off first (optional)', done: fees?, optional: true },
      { key: 'activate', label: 'Activate the plan', done: @plan.is_active }
    ]
  end

  def summary
    return [] if @components.empty?

    roles = @components.map { |c| role_of(c) }.uniq & CommissionPlanTester::SAMPLE_PEOPLE.keys
    engine = CommissionPaymentGeneratorService.new(CommissionPlanTester.sample_deal(@plan, SAMPLE, roles))
    fees = engine.fees_for(SAMPLE_PROFIT)
    left = SAMPLE_PROFIT - fees.sum { |f| f[:amount] }

    lines = ["On a deal with #{money(SAMPLE_PROFIT)} of profit:"]
    lines += fees.map { |f| fee_sentence(f) }
    lines += (@components - @components.select { |c| fee_ids.include?(c.id) }).map { |c| pay_sentence(c, engine, left) }
    lines << split_sentence if split_applies?
    lines
  end

  def fee_sentence(fee)
    return "#{money(fee[:amount])} #{fee[:name]} stays with the company." if fee[:role].blank?

    "#{money(fee[:amount])} #{fee[:name]} goes to the #{person(fee[:role]).downcase}, only when someone holds that position."
  end

  def pay_sentence(component, engine, left)
    who = component.applies_to_role == 'all_participants' ? 'Everyone on the deal' : "The #{person(role_of(component)).downcase}"
    amount = engine.component_line(component, role_of(component))[:amount]
    return "#{who} earns #{component.calculation_description}." unless component.component_type.in?(PERCENT_TYPES)

    rate = "#{(component.rate.to_d * 100).to_f.to_s.delete_suffix('.0')}%"
    name = PROFIT_NAMES[component.gross_type.to_s]
    return "#{who} earns #{rate} of #{OTHER_BASES.fetch(component.gross_type.to_s, 'the gross')}." unless name

    base = fees? ? "#{money(left)}, the #{name} left after fees" : "#{money(SAMPLE_PROFIT)} of #{name}"
    "#{who} earns #{rate} of #{base}: #{money(amount)}."
  end

  def split_applies?
    @components.any? { |c| role_of(c) == :primary_salesperson } && @components.none? { |c| role_of(c) == :secondary_salesperson }
  end

  def split_sentence
    engine = CommissionPaymentGeneratorService.new(CommissionPlanTester.sample_deal(@plan, SAMPLE, split_roles))
    "With a second salesperson, they split it evenly: #{money(engine.total_for_role(:primary_salesperson))} and " \
      "#{money(engine.total_for_role(:secondary_salesperson))}."
  end

  def split_roles
    (@components.map { |c| role_of(c) }.uniq & CommissionPlanTester::SAMPLE_PEOPLE.keys) | [:secondary_salesperson]
  end

  def warnings
    [fee_base_warning, two_rates_warning, assigned_person_warning].compact
  end

  def fee_base_warning
    other = percents.reject { |c| c.gross_type == 'house_profit' }
    return unless fees? && other.any?

    "#{other.map(&:name).join(', ')} pays on more than the home, so delivery and site work profit earns commission. " \
      'Choose House Profit if you pay on the home only.'
  end

  def two_rates_warning
    first = percents.select { |c| role_of(c) == :primary_salesperson }.sum { |c| c.rate.to_d }
    second = percents.select { |c| role_of(c) == :secondary_salesperson }.sum { |c| c.rate.to_d }
    return unless first.positive? && second.positive?

    "With two salespeople this plan pays #{pct(first)} plus #{pct(second)}, #{pct(first + second)} in total, because each earns their own rate. " \
      "To split one rate between them, remove the second salesperson's component."
  end

  def assigned_person_warning
    return if @plan.assigned_user_id.blank? || @components.any? { |c| role_of(c) == :primary_salesperson }

    "This plan is used on deals #{@plan.assigned_user&.name} sells, and it pays the salesperson nothing. " \
      'To pay someone a fee, add it to the plan your salespeople use instead.'
  end

  def person(role)
    CommissionPlanTester::ROLE_LABELS.fetch(role.to_sym, role.to_s.humanize)
  end

  def pct(rate)
    "#{(rate * 100).to_f.to_s.delete_suffix('.0')}%"
  end

  def money(amount)
    ActiveSupport::NumberHelper.number_to_currency(amount)
  end
end
