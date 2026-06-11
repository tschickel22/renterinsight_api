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

  # ── Item resolution (shared by inventory + deal worksheets) ──────────────────
  #
  # Given raw line items and the company's allowance defaults, split them into:
  #   - adds:       calculator selections for items that map to a lender allowance
  #                 (these contribute their Std/Max allowance to F — Option A).
  #   - line_items: a display list of EVERY item, each flagged allowance-backed or not,
  #                 so the worksheet can show the full configured home while only
  #                 allowance-backed items move the Max Advance ceiling.
  #
  # `items` is an array of hashes: { name:, price:, qty:, allowance_default_id: (optional) }.
  #   - inventory packages: pass name + price + qty:1; allowance_default_id is nil, so we
  #     resolve by NAME against company_allowance_defaults (matches the inventory hint logic).
  #   - deal standard_item lines: pass allowance_default_id (from the `allowance:<id>` tag)
  #     for an exact match; falls back to name if the id doesn't resolve.
  #
  # Non-allowance items (templates, custom) are returned in line_items with
  # allowance_backed: false and DO NOT appear in adds — they're dealer add-ons the lender
  # won't advance, shown for transparency only.
  def resolve_items(company:, items:)
    defaults_by_id   = company.company_allowance_defaults.active.index_by(&:id)
    defaults_by_name = company.company_allowance_defaults.active.index_by { |d| d.name.to_s.strip.downcase }

    adds = []
    line_items = Array(items).map do |item|
      item = item.symbolize_keys if item.respond_to?(:symbolize_keys)
      name  = item[:name].to_s
      price = item[:price].to_f
      qty   = item[:qty].to_i.positive? ? item[:qty].to_i : 1

      default =
        (defaults_by_id[item[:allowance_default_id].to_i] if item[:allowance_default_id]) ||
        defaults_by_name[name.strip.downcase]

      if default
        adds << { category: default.category, name: default.name, material: default.material, qty: qty }
        {
          name: name.presence || default.name,
          price: price,
          qty: qty,
          allowance_backed: true,
          allowance_default_id: default.id,
          standard_allowance: default.standard_allowance&.to_f,
          maximum_allowance: default.maximum_allowance&.to_f
        }
      else
        { name: name, price: price, qty: qty, allowance_backed: false }
      end
    end

    { adds: adds, line_items: line_items }
  end
end
