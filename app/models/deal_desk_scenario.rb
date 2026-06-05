# frozen_string_literal: true

# A Deal Desk scenario — the working scratchpad and unit of persistence. A deal can have
# MANY scenarios (the compare feature); each may reference a different unit (unit-swap).
#
# Lifecycle (never hard-deleted — expire, don't prune):
#   active   — within the validity window, editable, shown in the working desk
#   expired  — past the window: read-only, hidden from default view, retrievable via history
#   selected — chosen/closed: kept permanently regardless of window
#
# Dealer gross fields (front_gross/back_gross/dealer_gross) are INTERNAL ONLY. Use
# #customer_h for any customer-facing surface (the pencil PDF, generated quotes).
class DealDeskScenario < ApplicationRecord
  include LocationAware

  STATUSES = %w[active expired selected].freeze

  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :deal
  belongs_to :vehicle, optional: true
  belongs_to :lender_program, optional: true
  belongs_to :quote, optional: true
  belongs_to :created_by, class_name: 'User', foreign_key: 'created_by_id', optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :tax_mode, inclusion: { in: DealDesk::Engine::TAX_MODES.map(&:to_s) }

  scope :active,   -> { where(status: 'active') }
  scope :expired,  -> { where(status: 'expired') }
  scope :selected, -> { where(status: 'selected') }
  # Offerable = active AND still inside its validity window.
  scope :offerable, -> { active.where('valid_through IS NULL OR valid_through >= ?', Date.current) }
  scope :recent,    -> { order(created_at: :desc) }

  before_validation :set_validity_window, on: :create
  before_save :stringify_jsonb

  # Engine inputs assembled from this scenario's snapshot + working structure. Shared by
  # the controller (recompute on autosave) and the PDF generator so they never diverge.
  def engine_inputs
    {
      price: unit_price_snapshot,
      unit_cost: unit_cost_snapshot,
      pack_amount: (company&.respond_to?(:default_pack_amount) ? company.default_pack_amount : 0),
      trade_allowance: trade_allowance, trade_payoff: trade_payoff,
      cash_down: cash_down, rebates: rebates,
      fees: fees || {},
      fni_products: Array(fni_products).map { |p| p = p.symbolize_keys; { price: p[:price], cost: p[:cost] } },
      # Snapshotted deal add-ons (non-home deal_products). The engine takes price/cost
      # per line; fold quantity into the engine input here (do NOT mutate the stored
      # snapshot) so a qty>1 line contributes its full line total to OTD/front gross.
      # DEDUP: drop any line item that collides (normalized name + price) with an
      # fni_products entry. Round-trip hazard — an F&I product applied to the deal becomes a
      # deal_product, which a later scenario re-snapshots as a line item; if the working desk
      # still carries it as F&I, the engine would count it in BOTH total_fni and
      # total_line_items. fni_products is authoritative (the rep explicitly chose it), so the
      # re-snapshotted line-item copy is the one dropped. Filtering only the engine input
      # leaves the stored line_items/fni_products columns untouched.
      line_items: deduped_line_items_for_engine,
      tax_rate: tax_rate, tax_mode: (tax_mode || 'full_price').to_sym,
      apr: apr, term_months: term_months
    }
  end

  def engine_result
    DealDesk::Engine.compute(engine_inputs)
  end

  # Has the price moved since this scenario was quoted? (snapshot vs. live). The snapshot is
  # now sourced from the deal (snapshot_unit!), so compare against the deal's current
  # selling_price — NOT vehicle.sale_price, which can legitimately differ from the quoted price.
  def price_changed?
    return false if deal.nil? || unit_price_snapshot.nil?

    current = deal.selling_price
    current.present? && current.to_d != unit_price_snapshot.to_d
  end

  # Past its window and not locked in as the selected/closed structure.
  def expired_by_window?
    status != 'selected' && valid_through.present? && valid_through < Date.current
  end

  # Single-selection invariant: at most one selected scenario per deal. Selecting this one
  # first demotes any OTHER currently-selected sibling back to 'active' (never touches
  # expired ones). Done in a transaction so the flip is atomic.
  def mark_selected!
    transaction do
      deal.deal_desk_scenarios.selected.where.not(id: id).update_all(status: 'active')
      update!(status: 'selected', selected_at: Time.current)
    end
  end

  # Write this scenario's structure back onto the deal. Two modes:
  #   assign_only: false (default) — deal.update; used by the controller #apply action
  #                                  (the deliberate, manual pre-close write-back).
  #   assign_only: true            — pure assignment (deal.attr = ...) for use INSIDE a deal
  #                                  save (the on_close before_save hook). Folding into the
  #                                  in-flight UPDATE means no nested deal.update and so no
  #                                  save re-entrancy.
  # Writes ONLY the structured economic fields — never the close/GL/commission state.
  def write_back_to_deal!(deal = self.deal, assign_only: false)
    attrs = {
      vehicle_id: vehicle_id,
      selling_price: unit_price_snapshot,
      # Server-populated snapshot of the unit's real cost (snapshot_unit!), never view-gated.
      # Written to BOTH cost columns: unit_cost (deal-level gross helper) and home_cost — the
      # canonical accounting cost the GL COGS line actually reads (DealAccountingService), per
      # the deal_approvals unit_cost->home_cost alias. Keeps COGS consistent with the swapped
      # unit's revenue at close. compacted, so a unit with no cost on record nils out neither.
      unit_cost: unit_cost_snapshot,
      home_cost: unit_cost_snapshot,
      trade_allowance: trade_allowance,
      trade_payoff: trade_payoff,
      down_payment: cash_down,
      # Fees are NO LONGER written to the deprecated fee columns (doc_fee/delivery_fee/
      # setup_fee/skirting_fee/accessories_total). The FE zeroes those columns on every deal
      # save (Phase 3: fees moved to line items), so writing them here is dead storage. Fees
      # are instead merged as 'category:fee' deal_products by merge_line_items_and_fni_to_deal!
      # (called from #apply). NOTE: backend readers of those columns (Deal#addon_gross ->
      # commissions, DealInvoiceService, agreement merge-fields) are a separate, deferred
      # reader-migration (Part c) — intentionally NOT touched here.
      # Lender: the scenario has no lender_name column — the name lives on the selected
      # financing program (LenderProgram#lender_name). lender_id is intentionally NOT
      # written: LenderProgram has no FK to the managed Lender list that Deal#lender_id
      # references, so there is no clean mapping. Writing lender_name alone is safe — the
      # deal's denormalize_lender_name callback only fires on lender_id changes.
      lender_name: lender_program&.lender_name,
      # Cash vs financed, derived from the engine's financed amount.
      payment_type: (amount_financed.to_f > 0 ? 'financed' : 'cash'),
      financed_amount: amount_financed
    }.compact

    if assign_only
      attrs.each { |attr, value| deal.public_send("#{attr}=", value) }
    else
      deal.update(attrs)
    end
  end

  # Snapshot the deal's line items onto this scenario for the INITIAL scenario (the unit is the
  # deal's home). The list = deal add-ons (non-home, and excluding the home's packages by
  # match) tagged source 'deal' + the home's packages tagged source 'home'. The home line
  # itself is excluded — the engine counts it once via `price` (unit_price_snapshot).
  #
  # Home-package source: if the deal carries 'package'-tagged lines, those are authoritative
  # (the rep may have edited a package's price/cost on the deal). Otherwise (untagged data —
  # some deals store the home's packages as plain deal_products) fall back to the unit's
  # inventory_packages so they still appear exactly once. Either way deal_addon_line_entries
  # excludes the unit's packages by match, so nothing is double-counted.
  def snapshot_line_items_from_deal!(deal = self.deal)
    tagged_home_packages = deal_home_package_entries(deal)
    home_packages = tagged_home_packages.any? ? tagged_home_packages : home_package_entries(deal.vehicle)

    self.line_items =
      (deal_addon_line_entries(deal, deal.vehicle) + home_packages).map(&:stringify_keys)
  end

  # Re-sync line items when the scenario's unit changes (the compare "Use this unit" swap).
  # Rebuilds the list DETERMINISTICALLY from two clean sources rather than mutating the prior
  # state — so it also self-heals any stale/mis-tagged home line left by an earlier snapshot:
  #   - DEAL add-ons: the deal's genuine non-home, non-package line items (manual/template adds
  #     that ride with the deal regardless of unit) — tagged source 'deal'.
  #   - HOME packages: the CURRENT scenario unit's inventory packages (included_in_total) —
  #     tagged source 'home'. The OLD unit's packages simply aren't pulled, so they drop.
  # Fees + F&I (separate JSONB columns) are untouched and persist across the swap. The caller
  # (controller #update) runs recompute! afterward so the recap/grid reflect the new set.
  # The old_vehicle_id arg is retained for signature stability/logging but no longer needed for
  # filtering (the rebuild makes prior state irrelevant).
  # NOTE (Phase 5 boundary): this updates the SCENARIO for accurate display + payment math
  # only. It does NOT push the swapped unit or its lines onto the deal — that write-back is the
  # deferred Phase 5 unit-swap feature.
  def resync_line_items_for_unit!(_old_vehicle_id = nil)
    # Resolve the NEW unit explicitly (don't trust a possibly-cached `vehicle` association
    # after a vehicle_id reassignment). Reset the association so the next `vehicle` call
    # re-queries by the CURRENT vehicle_id rather than returning the stale cached record.
    association(:vehicle).reset
    new_unit = vehicle_id.present? ? vehicle : nil

    # Deal add-ons exclude packages from BOTH the deal's original home and the new unit
    # (match-based). That drops the OLD home's packages (even if they ride as untagged deal
    # lines) and prevents the NEW unit's packages from being counted twice (deal add-on +
    # inventory package). The unit's packages come solely from home_package_entries below.
    deal_addons = deal_addon_line_entries(deal, deal.vehicle, new_unit)

    self.line_items = (deal_addons + home_package_entries(new_unit)).map(&:stringify_keys)
  end

  # Merge this (selected) scenario's add-ons — line_items, fni_products, AND fees — onto the
  # deal as deal_products. ADD-ONLY with quantity reconciliation: never replaces, never removes,
  # and never touches the home line or any unmatched existing product. F&I products become
  # deal_products (sold as lines on the deal); fees become 'category:fee' line items matching
  # the FE convention (see fee_addon_entries) — fees no longer ride the deprecated fee columns.
  # Cost rides as 0 when unknown — the approval modal lets the approver confirm cost, so we
  # never prompt for it here.
  #
  # Matching is by normalized name AND exact price (two items differing in either stay
  # separate lines), against existing deal_products EXCLUDING the home (A1 heuristic):
  #   - same name+price, same qty   -> skip (already on the deal)
  #   - same name+price, diff qty   -> reconcile that line's quantity (no duplicate)
  #   - no match                    -> create a fresh CUSTOM- line
  # Idempotent: a second apply with no scenario changes does nothing. Returns a change summary.
  def merge_line_items_and_fni_to_deal!(deal = self.deal)
    added = []
    updated_qty = []
    skipped = 0

    existing   = deal.deal_products.to_a
    home       = identify_home_line(deal, existing)
    candidates = home ? existing - [home] : existing

    scenario_addon_entries.each do |entry|
      name  = entry[:name].to_s
      price = entry[:price].to_f
      qty   = (entry[:quantity] || 1).to_i
      qty   = 1 if qty <= 0

      match = candidates.find do |dp|
        normalize_name(dp.product_name) == normalize_name(name) && dp.unit_price.to_f == price
      end

      if match
        if match.quantity.to_i == qty
          skipped += 1
        else
          from = match.quantity.to_i
          match.update!(quantity: qty) # calculate_total recomputes total in before_save
          updated_qty << { id: match.id, name: match.product_name, from: from, to: qty }
        end
      else
        created = deal.deal_products.create!(
          product_name: name,
          product_sku: "CUSTOM-#{SecureRandom.hex(4)}",
          unit_price: price,
          cost: entry[:cost].to_f,
          quantity: qty,
          discount: 0,
          discount_type: 'fixed',
          tax: 0,
          notes: entry[:notes]
        )
        candidates << created # so a later identical entry reconciles instead of duplicating
        added << { id: created.id, name: created.product_name, price: price, quantity: qty }
      end
    end

    { added: added, updated_qty: updated_qty, skipped: skipped }
  end

  # Expire unless permanently kept (selected). Used by the expiry sweep.
  def expire!
    return if status == 'selected'

    update!(status: 'expired')
  end

  private

  # Pick the single deal_product that represents the home, or nil if it can't be done
  # unambiguously. Identification, most-reliable signal first:
  #   1. source_type == 'home'  — the FE tags the home line this way (DealLineItemsCard); it's
  #      an indexed column and the authoritative marker. Used when exactly one such line exists.
  #   2. VEHICLE--<id> SKU tag  — belt-and-suspenders for lines created via the deal-products
  #      controller path (when exactly one such tag exists).
  #   3. price+name match       — last-resort heuristic: unit_price == deal.selling_price AND
  #      (when a vehicle is linked) name matches the vehicle's year/make/model. NOTE this is
  #      unreliable when the home rides at its BASE price while selling_price is the package-
  #      inclusive TOTAL — hence steps 1–2 take precedence.
  # Returns nil and warns on 0 or >1 matches at the heuristic stage so the caller excludes none
  # rather than guessing.
  def identify_home_line(deal, products)
    # (1) Authoritative: the FE-tagged home line.
    typed = products.select { |dp| dp.source_type.to_s == 'home' }
    return typed.first if typed.size == 1

    # (2) Belt-and-suspenders: a properly VEHICLE--tagged home.
    tagged = products.select do |dp|
      (dp.referenced_vehicle_id.present? && dp.referenced_vehicle_id == deal.vehicle_id) ||
        dp.vehicle_line_item?
    end
    return tagged.first if tagged.size == 1

    # (3) Last-resort price+name heuristic.
    selling      = deal.selling_price.to_f
    vehicle_name = deal.vehicle ? normalize_name(vehicle_display_name(deal.vehicle)) : nil

    candidates = products.select do |dp|
      price_match = selling.positive? && dp.unit_price.to_f == selling
      name_match  = vehicle_name.blank? || normalize_name(dp.product_name) == vehicle_name
      price_match && name_match
    end

    return candidates.first if candidates.size == 1

    if products.any?
      Rails.logger.warn(
        "[DealDeskScenario] snapshot_line_items_from_deal!: ambiguous home line for deal " \
        "#{deal.id} (selling_price=#{selling}, candidates=#{candidates.size}); excluding none."
      )
    end
    nil
  end

  # Display names for the fees JSONB keys when merged as fee line items.
  FEE_LINE_NAMES = {
    'doc' => 'Doc Fee', 'delivery' => 'Delivery Fee', 'setup' => 'Setup Fee',
    'skirting' => 'Skirting Fee', 'accessories' => 'Accessories'
  }.freeze

  # Flatten this scenario's add-ons into a uniform {name, price, cost, quantity, notes} list:
  # line_items (snapshotted deal add-ons), fni_products (sold as lines, qty 1), and fees (the
  # fees JSONB, emitted as fee line items). Blank-named entries are dropped.
  #
  # HOME-sourced line items are EXCLUDED here: they're the swapped/selected unit's own
  # inventory packages, pulled in for display + payment math. Pushing them onto the deal is
  # the deferred Phase 5 unit-swap write-back (which also swaps the deal's home line). Until
  # then, apply must stay home-line-free, so we only merge 'deal'-sourced (and untagged)
  # add-ons. Untagged lines (source nil) are legacy/deal add-ons and DO merge.
  def scenario_addon_entries
    items = Array(line_items).map(&:symbolize_keys).reject { |li| li[:source].to_s == 'home' }.map do |li|
      { name: li[:description].to_s, price: li[:price].to_f, cost: li[:cost].to_f,
        quantity: (li[:quantity] || 1), notes: nil }
    end
    fni = Array(fni_products).map do |p|
      p = p.symbolize_keys
      { name: p[:name].to_s, price: p[:price].to_f, cost: p[:cost].to_f, quantity: 1, notes: nil }
    end
    (items + fni + fee_addon_entries).reject { |e| e[:name].strip.empty? }
  end

  # Scenario fees (fees JSONB: doc/delivery/setup/skirting/accessories) as fee line items,
  # matching the FE convention (DealForm.tsx): notes carry the 'category:fee' tag so
  # DealLineItemsCard displays/edits them identically to FE-entered fees. Zero/blank fees are
  # skipped; fees are pure charges (cost 0, qty 1). For a plain fee the FE's notes-join
  # collapses to exactly 'category:fee' (no notes/source/commissionable tags), so we match that.
  def fee_addon_entries
    (fees || {}).filter_map do |key, value|
      amount = value.to_f
      next if amount <= 0

      # Only emit known fee keys. The fees JSONB can carry UI artifacts (e.g. a key named
      # after the amount, "50"=>50); skipping unknown keys keeps junk out of deal_products.
      name = FEE_LINE_NAMES[key.to_s]
      if name.nil?
        Rails.logger.warn(
          "[DealDeskScenario] fee_addon_entries: skipping unknown fee key #{key.inspect} " \
          "(scenario #{id || 'new'}, deal #{deal_id}); not a recognized fee."
        )
        next
      end

      { name: name, price: amount, cost: 0.0, quantity: 1, notes: 'category:fee' }
    end
  end

  # Engine-bound line items with quantity folded in, minus any entry that collides
  # (normalized name + price) with an fni_products entry. See engine_inputs for the rationale.
  def deduped_line_items_for_engine
    fni_keys = Array(fni_products).map do |p|
      p = p.symbolize_keys
      [normalize_name(p[:name]), p[:price].to_f]
    end.to_set

    Array(line_items).reject do |li|
      li = li.symbolize_keys
      fni_keys.include?([normalize_name(li[:description]), li[:price].to_f])
    end.map do |li|
      li = li.symbolize_keys
      qty = (li[:quantity] || 1).to_f
      { price: li[:price].to_f * qty, cost: li[:cost].to_f * qty }
    end
  end

  def vehicle_display_name(vehicle)
    [vehicle.try(:year), vehicle.try(:make), vehicle.try(:model)].compact.join(' ')
  end

  # Build 'home'-sourced line item entries from a unit's inventory packages (the Premium
  # Roofing / Porch rows on the inventory record). Only packages flagged include_in_total are
  # pulled — matching the home's own Total Home Price and the deal-form behavior. Symbol-keyed
  # here; the caller stringifies. Returns [] for a nil unit or a unit with no packages (the
  # common MH case where the home is just a price). Used for a SWAPPED-IN unit (no deal values
  # exist yet, so the inventory record is authoritative).
  def home_package_entries(unit)
    return [] unless unit.respond_to?(:inventory_packages)

    unit.inventory_packages.included_in_total.ordered.map do |pkg|
      {
        description: pkg.name,
        price: pkg.price.to_f,
        cost: pkg.cost.to_f,
        quantity: 1,
        source: 'home',
        source_vehicle_id: unit.id
      }
    end
  end

  # The deal's genuine add-on lines: deal_products that are NEITHER the home line NOR a home
  # package. These ride with the DEAL regardless of which unit the scenario structures around
  # (manual items, templates, land, etc.) — tagged source 'deal' so a unit swap keeps them.
  # Symbol-keyed; caller stringifies.
  #
  # IMPORTANT — package exclusion is by MATCH against a set of units, not just by tag. On some
  # deals the home's packages ride as deal_products WITHOUT source_type 'package' (older data /
  # lines added before tagging). Tag-only exclusion would then (a) duplicate them on a swap-back
  # (counted as a deal add-on AND pulled from inventory_packages), and (b) leak the OLD home's
  # packages forward on a swap to a different unit. So we exclude any deal line whose normalized
  # name+price matches a package on ANY unit in `package_units` — pass both the deal's original
  # home and the unit being structured around so neither home's packages survive as add-ons.
  def deal_addon_line_entries(deal, *package_units)
    units = package_units.compact
    units = [deal.vehicle].compact if units.empty?
    package_keys = units.flat_map { |u| unit_package_keys(u).to_a }.to_set

    products = deal.deal_products.to_a
    home = identify_home_line(deal, products)
    candidates = home ? products - [home] : products

    addons = candidates.reject do |dp|
      dp.source_type.to_s == 'package' ||
        package_keys.include?([normalize_name(dp.product_name), dp.unit_price.to_f])
    end

    addons.map do |dp|
      {
        description: dp.product_name,
        price: dp.unit_price.to_f,
        cost: dp.cost.to_f,
        quantity: (dp.quantity || 1),
        source: 'deal',
        source_vehicle_id: nil
      }
    end
  end

  # (normalized name, price) pairs for a unit's included_in_total inventory packages — used to
  # match-and-exclude home packages that ride as untagged deal_products. Empty for a nil unit.
  def unit_package_keys(unit)
    return [].to_set unless unit.respond_to?(:inventory_packages)

    unit.inventory_packages.included_in_total.map do |pkg|
      [normalize_name(pkg.name), pkg.price.to_f]
    end.to_set
  end

  # The deal home's package lines (source_type 'package' deal_products) as 'home'-sourced
  # entries tied to the deal's current vehicle. Used at CREATE, where the deal's values are
  # authoritative (the rep may have edited a package on the deal). Symbol-keyed; caller
  # stringifies.
  def deal_home_package_entries(deal)
    deal.deal_products.select { |dp| dp.source_type.to_s == 'package' }.map do |dp|
      {
        description: dp.product_name,
        price: dp.unit_price.to_f,
        cost: dp.cost.to_f,
        quantity: (dp.quantity || 1),
        source: 'home',
        source_vehicle_id: deal.vehicle_id
      }
    end
  end

  def normalize_name(str)
    str.to_s.strip.downcase.gsub(/\s+/, ' ')
  end

  def set_validity_window
    days = company&.deal_desk_scenario_validity_days || 30
    self.valid_through ||= days.days.from_now.to_date
  end

  # JSONB metadata stored with string keys (prevents symbol-key drift — CLAUDE.md rule 5).
  def stringify_jsonb
    self.fees = fees.deep_stringify_keys if fees.is_a?(Hash)
    self.fni_products = fni_products.map { |p| p.is_a?(Hash) ? p.deep_stringify_keys : p } if fni_products.is_a?(Array)
    self.line_items = line_items.map { |li| li.is_a?(Hash) ? li.deep_stringify_keys : li } if line_items.is_a?(Array)
  end
end
