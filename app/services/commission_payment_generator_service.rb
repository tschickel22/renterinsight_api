# frozen_string_literal: true

# The commission engine: what each person on a deal is paid under the deal's
# commission plan. Real payments (generate), the deal preview (preview), the
# components page "test calculate" and the AI connector's simulation all go
# through lines_for_role, so they cannot disagree.
#
# Rules, per component:
#   percent_of_gross  rate x the gross named by gross_type
#   addon_commission  rate x add-on gross, whatever gross_type says (the UI
#                     used to save add-on components with commissionable front)
#   flat_per_unit     flat_amount x the deal's quantity (at least 1)
#   volume_bonus      flat_amount once per person per month or quarter, on the
#                     won deal that brings that person's count to exactly
#                     units_threshold; every other deal in the period gets 0
#
# A component limited to new or used, or to MH or RV, applies only to deals
# known to be that kind (Deal#commission_deal_type, #commission_vertical); a
# deal whose kind is unknown gets only the components meant for all deals.
#
# Split deals: when a secondary salesperson is on the deal, the primary
# salesperson's components (role primary_salesperson, or none) are split
# 50/50, cents left over going to the primary. Volume bonuses are personal and
# never split. The secondary is also paid components set for the secondary
# role, and everyone on the deal is paid all_participants components in full.
class CommissionPaymentGeneratorService
  ROLE_FIELDS = {
    primary_salesperson: :primary_salesperson_id,
    sales_manager: :sales_manager_id,
    finance_manager: :finance_manager_id,
    desk_manager: :desk_manager_id,
    secondary_salesperson: :secondary_salesperson_id
  }.freeze

  SPLIT_SHARE = BigDecimal('0.5')
  VOLUME_NOT_SPLIT_NOTE = 'not split; volume bonuses pay in full to the person who reached the threshold'

  def self.generate_for_deal(deal)
    new(deal).generate
  end

  def self.preview_for_deal(deal)
    new(deal).preview
  end

  # volume_position: for simulations only, the deal's place in the person's
  # count for the bonus period (5 = the fifth unit). Real deals count their own.
  def initialize(deal, volume_position: nil)
    @deal = deal
    @volume_position = volume_position
  end

  def generate
    return nil unless @deal.stage_is_won?
    return nil unless @deal.commission_plan.present?

    payments = []
    ROLE_FIELDS.each { |role, field| process_participant(role, @deal.public_send(field), payments) }
    payments.compact
  end

  def preview
    previews = []
    ROLE_FIELDS.each { |role, field| preview_participant(role, @deal.public_send(field), previews) }

    {
      can_generate: can_generate?,
      reasons: generation_reasons,
      participants: previews,
      total_commission: previews.sum { |p| p[:estimated_amount] },
      deal_economics: build_deal_economics
    }
  end

  # What the person in this role is paid on this deal, one line per component:
  # { component:, amount: (BigDecimal), note: }. Lines that pay nothing stay
  # in with a note, so a preview can say why.
  def lines_for_role(role)
    plan = @deal.commission_plan
    return [] unless plan

    components = plan.commission_components.where(is_active: true).ordered.to_a
    applicable = components.select { |c| c.applies_to_deal?(@deal) }
    everyone = applicable.select { |c| c.applies_to_role == 'all_participants' }

    case role
    when :primary_salesperson
      own = applicable.select { |c| primary_component?(c) }.map { |c| line(c, role) }
      own = own.map { |l| split_line(l, :primary) } if split?
      own + everyone.map { |c| line(c, role) }
    when :secondary_salesperson
      shared = split? ? applicable.select { |c| primary_component?(c) && c.component_type != 'volume_bonus' } : []
      shared.map { |c| split_line(line(c, :primary_salesperson), :secondary) } +
        applicable.select { |c| c.applies_to_role == 'secondary_salesperson' }.map { |c| line(c, role) } +
        everyone.map { |c| line(c, role) }
    else
      applicable.select { |c| c.applies_to_role.in?([role.to_s, 'all_participants']) }.map { |c| line(c, role) }
    end
  end

  def total_for_role(role)
    lines_for_role(role).sum(BigDecimal('0')) { |l| l[:amount] }.round(2)
  end

  # One component on its own, as the person in role would be paid it before
  # any split: { component:, amount:, note: }. Says so when the component
  # does not apply to this deal. Used by the components page test.
  def component_line(component, role = :primary_salesperson)
    unless component.applies_to_deal?(@deal)
      limits = [component.deal_type, component.vertical].compact_blank.reject { |v| v == 'all' }.join(' ')
      return { component: component, amount: BigDecimal('0'), note: "does not apply: limited to #{limits} deals" }
    end

    line(component, role)
  end

  def calculate_component_amount(component)
    component_line(component)[:amount]
  end

  private

  def primary_component?(component)
    component.applies_to_role.nil? || component.applies_to_role == 'primary_salesperson'
  end

  def split?
    secondary = @deal.try(:secondary_salesperson_id)
    secondary.present? && secondary != @deal.try(:primary_salesperson_id)
  end

  # Volume bonuses belong to the person and are never split. The note says
  # so, so a split deal's bonus line does not read as an unsplit mistake.
  def split_line(line, side)
    if line[:component].component_type == 'volume_bonus' && side == :primary
      return line.merge(note: [line[:note], VOLUME_NOT_SPLIT_NOTE].compact.join('; '))
    end

    full = line[:amount]
    secondary_share = (full * SPLIT_SHARE).floor(2)
    amount = side == :secondary ? secondary_share : full - secondary_share
    line.merge(amount: amount, note: [line[:note], "split 50/50 with the #{side == :primary ? 'secondary' : 'primary'} salesperson"].compact.join('; '))
  end

  def line(component, role)
    amount, note =
      case component.component_type
      when 'volume_bonus' then volume_bonus(component, role)
      when 'flat_per_unit'
        units = [@deal.try(:quantity).to_i, 1].max
        [component.flat_amount.to_d * units, units > 1 ? "#{units} units" : nil]
      when 'addon_commission' then [percent_of(@deal.addon_gross, component.rate), nil]
      when 'percent_of_gross', 'percentage' then [percent_of(gross_for(component.gross_type), component.rate), nil]
      else [BigDecimal('0'), "unknown component type #{component.component_type}"]
      end
    { component: component, amount: amount.to_d.round(2), note: note }
  end

  def percent_of(base, rate)
    base = base.to_d
    return BigDecimal('0') if base <= 0

    base * rate.to_d
  end

  def gross_for(gross_type)
    case gross_type
    when 'front', 'front_gross' then @deal.front_gross
    when 'commissionable_front', 'commissionable_front_gross' then @deal.commissionable_front_gross
    when 'back', 'back_gross' then @deal.back_gross
    when 'total', 'total_gross' then @deal.total_gross
    when 'addon', 'addon_gross' then @deal.addon_gross
    when 'selling_price' then @deal.selling_price
    end
  end

  def volume_bonus(component, role)
    threshold = component.units_threshold.to_i
    return [BigDecimal('0'), 'no unit threshold set'] if threshold <= 0

    position = @volume_position || volume_position_for(role, component.threshold_period)
    return [BigDecimal('0'), 'no person in this role on the deal'] if position.nil?

    period = component.threshold_period == 'quarterly' ? 'quarter' : 'month'
    if position == threshold
      [component.flat_amount.to_d, "unit #{position} this #{period}, reaches the #{threshold} unit bonus"]
    else
      [BigDecimal('0'), "unit #{position} this #{period}; the bonus pays once, on unit #{threshold}"]
    end
  end

  # This deal's place among the person's won deals in the bonus period, in
  # close date order (then id), counting this deal as closing on its own date.
  def volume_position_for(role, threshold_period)
    user_id = @deal.public_send(ROLE_FIELDS.fetch(role))
    return nil if user_id.blank?

    closed_on = close_date(@deal)
    range = threshold_period == 'quarterly' ? closed_on.all_quarter : closed_on.all_month
    close_sql = 'COALESCE(deals.actual_close_date, deals.delivery_date, CAST(deals.updated_at AS date))'

    others = @deal.company.deals.where(deleted_at: nil)
                  .where(ROLE_FIELDS.fetch(role) => user_id)
                  .where('LOWER(deals.stage) IN (?)', @deal.company.won_stage_keys)
                  .where("#{close_sql} BETWEEN ? AND ?", range.first, range.last)
    others = others.where.not(id: @deal.id) if @deal.id
    earlier = others.where("#{close_sql} < :d OR (#{close_sql} = :d AND deals.id < :id)",
                           d: closed_on, id: @deal.id || 2**62)
    earlier.count + 1
  end

  def close_date(deal)
    deal.actual_close_date || deal.try(:delivery_date) || deal.updated_at&.to_date || Date.current
  end

  def process_participant(role, user_id, payments)
    return unless user_id.present?
    return if CommissionPayment.exists?(deal_id: @deal.id, payee_user_id: user_id, is_deleted: [false, nil])

    lines = lines_for_role(role)
    return if lines.empty?

    commission_amount = lines.sum(BigDecimal('0')) { |l| l[:amount] }.round(2)
    return if commission_amount <= 0

    calculation_data = build_calculation_details_for_role(role, lines)
    calculation_data[:line_items] = build_line_items(lines)
    calculation_data[:deal_economics] = build_deal_economics

    payments << @deal.company.commission_payments.create!(
      deal_id: @deal.id,
      payee_user_id: user_id,
      commission_plan_id: @deal.commission_plan_id,
      amount: commission_amount,
      status: 'pending',
      location_id: @deal.location_id,
      calculation_details: calculation_data.deep_stringify_keys
    )
  end

  def preview_participant(role, user_id, previews)
    return unless user_id.present?

    user = User.find_by(id: user_id)
    return unless user

    lines = lines_for_role(role)
    return if lines.empty?

    previews << {
      role: role.to_s,
      user_id: user_id,
      user_name: user.name,
      estimated_amount: lines.sum(BigDecimal('0')) { |l| l[:amount] }.round(2).to_f,
      components: lines.map { |l| component_detail(l) }
    }
  end

  def can_generate?
    @deal.stage_is_won? &&
      @deal.commission_plan.present? &&
      @deal.primary_salesperson_id.present?
  end

  def generation_reasons
    reasons = []
    reasons << 'Deal must be closed won' unless @deal.stage_is_won?
    reasons << 'Deal must have a commission plan' unless @deal.commission_plan.present?
    reasons << 'Deal must have a primary salesperson assigned' unless @deal.primary_salesperson_id.present?
    reasons
  end

  def component_detail(line)
    c = line[:component]
    {
      component_id: c.id,
      name: c.name,
      type: c.component_type,
      gross_type: c.component_type == 'addon_commission' ? 'addon' : c.gross_type,
      rate: c.rate,
      flat_amount: c.flat_amount,
      amount: line[:amount].to_f,
      note: line[:note]
    }.compact
  end

  def build_calculation_details_for_role(role, lines)
    plan = @deal.commission_plan
    {
      role: role.to_s,
      plan_name: plan&.name,
      plan_id: plan&.id,
      split: split?,
      components: lines.map { |l| component_detail(l) }
    }
  end

  # component_id is what CommissionComponent#paid? looks for, so a component
  # that has been paid cannot be taken off its plan.
  def build_line_items(lines)
    lines.map do |l|
      c = l[:component]
      {
        component_id: c.id,
        description: c.name,
        component_type: c.component_type,
        gross_type: c.component_type == 'addon_commission' ? 'addon' : c.gross_type,
        rate: c.rate,
        flat_amount: c.flat_amount,
        amount: l[:amount].to_f,
        note: l[:note]
      }.compact
    end
  end

  def build_deal_economics
    {
      selling_price: @deal.selling_price,
      unit_cost: @deal.try(:unit_cost),
      front_gross: @deal.front_gross,
      commissionable_front_gross: @deal.commissionable_front_gross,
      back_gross: @deal.back_gross,
      total_gross: @deal.total_gross,
      addon_gross: @deal.addon_gross,
      pack_amount: @deal.try(:effective_pack_amount),
      trade_allowance: @deal.try(:trade_allowance),
      trade_payoff: @deal.try(:trade_payoff),
      finance_reserve: @deal.try(:finance_reserve),
      product_margin: @deal.try(:product_margin),
      quantity: @deal.try(:quantity)
    }
  end
end
