# frozen_string_literal: true

# MaxAdvanceSurfacing — Phase 4a. Thin read-only wrapper around MaxAdvanceCalculator
# (Phase 3, unchanged) for surfacing on deals and reports.
#
# It computes the Max Advance from the captured invoice + the lender's schedule and
# (for a deal) classifies the deal's home line-item price against the caps:
#   within_standard | within_maximum | over_maximum   (green / yellow / red)
#
# EXACTNESS: we pass NO speculative option adds. The figure is the lender's max advance
# on the base home from the captured invoice (markup of the net + freight/HUD/trim
# add-backs) — exact, never approximate. Home-option allowances (A/C, skirting, …) are
# funded separately per the lender schedule and are out of scope for this base figure.
# When the invoice or lender is missing we return nil MSPs + a reason so callers render
# "—" + a flag, consistent with the cost-not-entered pattern.
module MaxAdvanceSurfacing
  module_function

  # => { standard_msp:, maximum_msp:, breakdown:, path:, reason:, status: }
  def evaluate(vehicle:, lender:, deal: nil, price: nil)
    return failure(:no_vehicle) if vehicle.nil?
    return failure(:no_lender)  if lender.nil?

    result = MaxAdvanceCalculator.new(vehicle: vehicle, lender: lender, deal: deal).call
    result.merge(status: status_for(price, result))
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
    { standard_msp: nil, maximum_msp: nil, breakdown: {}, path: nil, reason: reason, status: nil }
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
