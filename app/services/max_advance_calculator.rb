# frozen_string_literal: true

# MaxAdvanceCalculator — Max Advance Phase 3. PURE calculation, no persistence, no UI.
#
# Computes a home's Standard MSP and Maximum MSP from:
#   - the vehicle's manufacturer invoice (VehicleInvoice, Phase 1), and
#   - the lender's calculation schedule (allowance/deletion items + markup config, Phase 2).
#
# Returns nil MSPs + a `reason` when required inputs are missing, so callers can render
# "—" and never approximate.
#
#   MaxAdvanceCalculator.new(vehicle:, lender:, deal: nil, options: {}).call
#   => { standard_msp:, maximum_msp:, breakdown: { A,B,C,D,E,F_standard,F_maximum,G_*,H,I_* },
#        path: :new|:used, reason: nil }
#
# ── WORKSHEET MODEL (validated against the Sunshine ARC1680-8004 worksheet) ───────────
# NEW HOME (21st worksheet):
#   A  = invoice.gross_invoice
#   B  = Σ deletions (lender deletion_items applied to this vehicle):
#          wheels/axles single|multi by sections; freight/hud/tax/rebate pulled from the
#          invoice via invoice_reference (abs); other configured amounts.
#   C  = A − B                                  (New Home Net Invoice — pre-markup)
#   D  = base_markup_pct + VEP adj (vep0/1/2)   (e.g. 145 + 5 = 150 for VEP0)
#   E  = C × D/100                              (markup applies to the NET only)
#   F  = ADD-BACKS (freight + hud + tax at ACTUAL invoice values — these were deleted from
#        the net so they aren't marked up, then added back) + ALLOWANCE adds (per-home
#        selections, each at standard_allowance for the Standard MSP / maximum_allowance
#        for the Maximum MSP; delivery&set adds wind-zone per-side adders; steps/decks is
#        rate-per-set capped at its maximum).
#   G  = E + F                                  (Total Home Value)
#   H  = sales tax not already on the invoice   (default 0 / options)
#   I  = G + H                                  (Maximum Sales Price of Home)  [+ land/impr]
#
# USED HOME: on-site = nada × onsite%; delivered = nada × delivered% + adds; repo = net + adds.
# ─────────────────────────────────────────────────────────────────────────────────────
class MaxAdvanceCalculator
  SECTION_VARIANT_CATEGORIES = %w[delivery_set trim_out footers pad].freeze

  # Deletion items (by name) that are ALSO added back in F at their actual invoice value —
  # the "bolded" lines appearing in both DELETIONS and ADDS on the worksheet. They are
  # removed before markup (so they aren't marked up), then restored at cost. Includes
  # trim_out: a manufacturer trim line is stripped + added back (multi-section PRI3280),
  # whereas a home with no invoice trim line takes trim as an allowance add instead.
  ADD_BACK_NAMES = %w[factory_freight hud_fees tax_from_invoice trim_out].freeze

  def initialize(vehicle:, lender:, deal: nil, options: {})
    @vehicle  = vehicle
    @lender   = lender
    @deal     = deal
    @options  = (options || {}).symbolize_keys
  end

  def call
    return failure(:cross_company, path_for_vehicle) unless same_company?

    used_path? ? calculate_used : calculate_new
  end

  private

  # ── Guards / context ────────────────────────────────────────────────────────

  def same_company?
    @vehicle.company_id.present? && @vehicle.company_id == @lender.company_id
  end

  def path_for_vehicle
    used_path? ? :used : :new
  end

  def used_path?
    return @options[:path].to_sym == :used if @options[:path]
    @vehicle.condition.to_s.downcase == 'used'
  end

  def invoice
    @invoice ||= @vehicle.invoice
  end

  def markup_config
    @markup_config ||= @lender.markup_config
  end

  def sections
    @vehicle.sections.to_i
  end

  def single_section?
    sections <= 1
  end

  def failure(reason, path)
    { standard_msp: nil, maximum_msp: nil, breakdown: {}, path: path, reason: reason }
  end

  def d(value)
    value.nil? ? BigDecimal('0') : BigDecimal(value.to_s)
  end

  # ── NEW HOME ─────────────────────────────────────────────────────────────────

  def calculate_new
    return failure(:no_invoice, :new) if invoice.nil?
    return failure(:missing_gross_invoice, :new) if invoice.gross_invoice.nil?
    return failure(:no_markup_config, :new) if markup_config.nil?

    a = d(invoice.gross_invoice)
    b = total_deletions
    c = a - b # New Home Net Invoice

    base   = d(markup_config.base_markup_pct)
    vep    = effective_vep_code
    markup = (base + vep_adjustment(vep)).round(4) # D — adjusted markup %
    e      = (c * markup / 100).round(2)           # Adjusted Markup Amount

    add_backs  = total_add_backs
    f_standard = (add_backs + allowance_adds(:standard)).round(2)
    f_maximum  = (add_backs + allowance_adds(:maximum)).round(2)

    h    = sales_tax
    land = d(@options[:land])
    impr = d(@options[:improvements])

    g_standard = (e + f_standard).round(2)
    g_maximum  = (e + f_maximum).round(2)
    i_standard = (g_standard + h + land + impr).round(2)
    i_maximum  = (g_maximum + h + land + impr).round(2)

    age = home_age

    {
      standard_msp: i_standard,
      maximum_msp:  i_maximum,
      path: :new,
      reason: nil,
      breakdown: {
        A: a.round(2),
        B: b.round(2),
        C: c.round(2),
        D: markup,
        E: e,
        add_backs: add_backs.round(2),
        F_standard: f_standard,
        F_maximum:  f_maximum,
        G_standard: g_standard,
        G_maximum:  g_maximum,
        H: h.round(2),
        I_standard: i_standard,
        I_maximum:  i_maximum,
        land: land.round(2),
        improvements: impr.round(2),
        vep_code: vep,
        markup_base_pct: base,
        home_age_years: age,
        age_exceeds_max: (age.present? && age > markup_config.max_age_years.to_i)
      }
    }
  end

  # B — sum of the lender's active deletion items applied to this vehicle.
  def total_deletions
    @lender.deletion_items.select(&:active).sum { |item| deletion_value(item) }
  end

  def deletion_value(item)
    if item.invoice_reference.present?
      # Pull from the invoice. A reference may combine fields with '+' (e.g.
      # 'hud_fees+state_assoc_fees' — the worksheet's single "HUD Dues/Fees" line is both).
      # Magnitude: sales_allowance is stored negative, so abs() makes each a positive deletion.
      return BigDecimal('0') if invoice.nil?
      item.invoice_reference.split('+').sum do |ref|
        field = ref.strip
        invoice.respond_to?(field) ? d(invoice.public_send(field)).abs : BigDecimal('0')
      end
    elsif item.single_amount.present? || item.multi_amount.present?
      d(single_section? ? item.single_amount : item.multi_amount)
    else
      d(item.amount)
    end
  end

  # The freight/hud/tax that were deleted from the net, added back at ACTUAL cost so they
  # appear in the final price without being marked up.
  def total_add_backs
    @lender.deletion_items.select(&:active)
           .select { |i| ADD_BACK_NAMES.include?(i.name.to_s) }
           .sum { |i| deletion_value(i) }
  end

  # Σ ALLOWANCE adds for a tier (:standard | :maximum). Adds are caller-supplied per-home
  # selections (from line items / captured config) — see options[:adds]. Empty => 0.
  def allowance_adds(tier)
    adds_selections.sum { |sel| allowance_add(sel, tier) }.round(2)
  end

  # Per-home selections (from line items / captured config) — see options[:adds].
  # IMPLICIT A/C: when the manufacturer invoice carries a factory-installed A/C line
  # (ac_from_invoice > 0), the 21st worksheet both DELETES that cost from the net AND
  # claims the A/C allowance in ADDS — even when no dealer A/C line item exists. We
  # mirror that by appending an implicit { category: 'ac' } selection, but ONLY when the
  # caller didn't already supply an explicit A/C add (dealer-installed line item), so the
  # allowance is never double-counted.
  def adds_selections
    @adds_selections ||= begin
      sels = Array(@options[:adds]).map { |s| s.respond_to?(:symbolize_keys) ? s.symbolize_keys : s }
      if d(invoice&.ac_from_invoice).positive? && sels.none? { |s| s[:category].to_s == 'ac' }
        sels + [{ category: 'ac', implicit: true }]
      else
        sels
      end
    end
  end

  def allowance_add(sel, tier)
    item = find_allowance(sel)
    return BigDecimal('0') unless item

    std = d(item.standard_allowance)
    max = d(item.maximum_allowance)
    qty = sel[:qty].nil? ? BigDecimal('1') : d(sel[:qty])

    amount =
      case item.category
      when 'steps_decks'
        # "1,000 each, max 3,000" — per-set rate (standard_allowance) × sets, capped at the
        # maximum. The cap is the same in both tiers, so the per-home set count drives it.
        [std * qty, max].min
      when 'hookups'
        # Genuine per-each rates that differ by tier (e.g. electric 1,500 / 2,500).
        (tier == :standard ? std : max) * qty
      else
        # flat / per_material / per_section_single|multi — the tier's allowance.
        tier == :standard ? std : max
      end

    amount += delivery_wind_zone_adder(item, sel) if item.category == 'delivery_set'
    amount
  end

  # delivery&set: + per-side adder for the home's wind zone × number of sides.
  def delivery_wind_zone_adder(item, sel)
    wz    = sel[:wind_zone] || invoice&.wind_zone
    sides = sel[:sides].nil? ? default_sides : d(sel[:sides])
    per_side = case wz.to_i
               when 2 then item.wind_zone2_adder_per_side
               when 3 then item.wind_zone3_adder_per_side
               else 0
               end
    d(per_side) * sides
  end

  # Worksheet wind-zone sides: 1 for single-section, 3 for multi-section (validated against
  # the worksheets — single 6,000+500×1=6,500; multi 12,000+500×3=13,500). Override per
  # selection with :sides.
  def default_sides
    single_section? ? BigDecimal('1') : BigDecimal('3')
  end

  # Resolve a selection to an allowance_item:
  #   - skirting: category + material
  #   - section-variant (delivery_set/trim_out/footers/pad): category + single/multi line
  #     (by pricing_basis) based on the vehicle's sections
  #   - hookups / others: category (+ name when given)
  def find_allowance(sel)
    items = @lender.allowance_items.select { |i| i.active && i.category == sel[:category].to_s }
    return nil if items.empty?

    if sel[:category].to_s == 'skirting'
      items.detect { |i| i.material.to_s.casecmp?(sel[:material].to_s) } || items.first
    elsif SECTION_VARIANT_CATEGORIES.include?(sel[:category].to_s)
      basis = single_section? ? 'per_section_single' : 'per_section_multi'
      items.detect { |i| i.pricing_basis == basis } || items.first
    elsif sel[:name].present?
      items.detect { |i| i.name.to_s.casecmp?(sel[:name].to_s) } || items.first
    else
      items.first
    end
  end

  # ── Markup / VEP ─────────────────────────────────────────────────────────────

  def effective_vep_code
    return @options[:vep_code].to_i if @options[:vep_code]
    invoice&.vep_code
  end

  def vep_adjustment(vep)
    case vep.to_i
    when 0 then d(markup_config.vep0_adj_pct)
    when 1 then d(markup_config.vep1_adj_pct)
    when 2 then d(markup_config.vep2_adj_pct)
    else BigDecimal('0')
    end
  end

  def home_age
    return nil if @vehicle.year.blank?
    yr = (@options[:current_year] || Date.current.year).to_i
    yr - @vehicle.year.to_i
  end

  # tax H — explicit option, else invoice tax if present, else 0.
  def sales_tax
    return d(@options[:sales_tax]) if @options.key?(:sales_tax)
    d(invoice&.tax_from_invoice)
  end

  # ── USED HOME ────────────────────────────────────────────────────────────────

  def calculate_used
    disposition = (@options[:used_disposition] || :on_site).to_sym
    nada = nada_base
    h    = sales_tax

    case disposition
    when :on_site
      return failure(:missing_nada_base, :used) if nada.nil?
      base = (nada * d(markup_config&.used_onsite_factor_pct) / 100).round(2)
      build_used(base, BigDecimal('0'), BigDecimal('0'), h, disposition, nada)
    when :delivered
      return failure(:missing_nada_base, :used) if nada.nil?
      base = (nada * d(markup_config&.used_delivered_factor_pct) / 100).round(2)
      build_used(base, total_add_backs + allowance_adds(:standard),
                 total_add_backs + allowance_adds(:maximum), h, disposition, nada)
    when :repo
      net = @options[:repo_net_price]
      return failure(:missing_repo_net_price, :used) if net.nil?
      build_used(d(net), total_add_backs + allowance_adds(:standard),
                 total_add_backs + allowance_adds(:maximum), h, disposition, nada)
    else
      failure(:unknown_used_disposition, :used)
    end
  end

  def nada_base
    return d(@options[:nada_base]) if @options.key?(:nada_base)
    invoice&.nada_base.nil? ? nil : d(invoice.nada_base)
  end

  def build_used(base, f_standard, f_maximum, h, disposition, nada)
    land = d(@options[:land])
    impr = d(@options[:improvements])
    i_standard = (base + f_standard + h + land + impr).round(2)
    i_maximum  = (base + f_maximum + h + land + impr).round(2)
    {
      standard_msp: i_standard,
      maximum_msp:  i_maximum,
      path: :used,
      reason: nil,
      breakdown: {
        used_disposition: disposition,
        nada_base: nada&.round(2),
        base_value: base,
        F_standard: f_standard.round(2),
        F_maximum:  f_maximum.round(2),
        H: h.round(2),
        I_standard: i_standard,
        I_maximum:  i_maximum,
        land: land.round(2),
        improvements: impr.round(2)
      }
    }
  end
end
