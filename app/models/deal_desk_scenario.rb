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
      tax_rate: tax_rate, tax_mode: (tax_mode || 'full_price').to_sym,
      apr: apr, term_months: term_months
    }
  end

  def engine_result
    DealDesk::Engine.compute(engine_inputs)
  end

  # Has the unit's price moved since this scenario was quoted? (snapshot vs. live).
  def price_changed?
    return false if vehicle.nil? || unit_price_snapshot.nil?

    current = vehicle.sale_price
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

  # Expire unless permanently kept (selected). Used by the expiry sweep.
  def expire!
    return if status == 'selected'

    update!(status: 'expired')
  end

  private

  def set_validity_window
    days = company&.deal_desk_scenario_validity_days || 30
    self.valid_through ||= days.days.from_now.to_date
  end

  # JSONB metadata stored with string keys (prevents symbol-key drift — CLAUDE.md rule 5).
  def stringify_jsonb
    self.fees = fees.deep_stringify_keys if fees.is_a?(Hash)
    self.fni_products = fni_products.map { |p| p.is_a?(Hash) ? p.deep_stringify_keys : p } if fni_products.is_a?(Array)
  end
end
