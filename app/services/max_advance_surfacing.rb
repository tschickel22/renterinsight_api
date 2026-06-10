# frozen_string_literal: true

# MaxAdvanceSurfacing — Phase 4a. Thin read-only wrapper around MaxAdvanceCalculator
# (Phase 3, unchanged) for surfacing on deals and reports.
#
# It computes the Max Advance from the captured invoice + the lender's schedule and
# (for a deal) classifies the deal's home line-item price against the caps:
#   within_standard | within_maximum | over_maximum   (green / yellow / red)
#
# TWO FIGURES (both exact, never approximate):
#   - BASE: the lender's max advance on the bare home from the captured invoice (markup of
#     the net + freight/HUD/trim add-backs), with NO option adds. This is what a lender
#     quotes on the home alone.
#   - CONFIGURED: BASE + the dealer-installed item allowances actually selected on the deal
#     (the `standard_item` line items, passed as `adds`). This matches the worksheet total
#     for a fully-configured home.
# The price is classified against the CONFIGURED caps when adds are present (that's what the
# home actually is), else against BASE. When the invoice or lender is missing we return nil
# MSPs + a reason so callers render "—" + a flag, consistent with the cost-not-entered pattern.
module MaxAdvanceSurfacing
  module_function

  # adds: array of calculator selections (see MaxAdvanceCalculator#allowance_add), each
  #   { category:, name:, material:, qty:, sides:, wind_zone: } — typically derived from the
  #   deal's standard_item lines. Empty/omitted => CONFIGURED equals BASE.
  #
  # => { standard_msp:, maximum_msp:,        # CONFIGURED (price is classified against these)
  #      base_standard_msp:, base_maximum_msp:,
  #      breakdown:, path:, reason:, status: }
  def evaluate(vehicle:, lender:, deal: nil, price: nil, adds: [])
    return failure(:no_vehicle) if vehicle.nil?
    return failure(:no_lender)  if lender.nil?

    base = MaxAdvanceCalculator.new(vehicle: vehicle, lender: lender, deal: deal).call

    configured =
      if Array(adds).any? && base[:reason].blank?
        MaxAdvanceCalculator.new(vehicle: vehicle, lender: lender, deal: deal, options: { adds: adds }).call
      else
        base
      end

    configured.merge(
      base_standard_msp: base[:standard_msp],
      base_maximum_msp:  base[:maximum_msp],
      status: status_for(price, configured)
    )
  end

  # Classify a price against the caps. nil when the calc has no result or no price.
  def status_for(price, result)
    return nil if result[:reason].present? || price.nil?

    std = result[:standard_msp]
    max = result[:maximum_msp]
    return nil if std.nil? || max.nil?

    p = BigDecimal(price.to_s)
    if    p <= BigDecimal(std.to_s) then 'within_standard'
    elsif p <= BigDecimal(max.to_s) then 'within_maximum'
    else  'over_maximum'
    end
  end

  def failure(reason)
    { standard_msp: nil, maximum_msp: nil, base_standard_msp: nil, base_maximum_msp: nil,
      breakdown: {}, path: nil, reason: reason, status: nil }
  end

  # Reason → report flag, consistent with the existing cost_not_entered flag pattern.
  def flag_for(reason)
    case reason
    when :no_invoice, :missing_gross_invoice then 'invoice_not_captured'
    when :no_lender                          then 'max_adv_no_lender'
    when :no_markup_config                   then 'lender_schedule_not_configured'
    else reason.to_s.presence
    end
  end
end
