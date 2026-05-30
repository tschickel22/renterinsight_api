# frozen_string_literal: true

# Company-level Deal Desk configuration (tunable, no code change required):
#   - comparable price-band width (default ±$15k OR ±10%)
#   - scenario validity window (default 30 days)
#   - days-on-lot tiers (default [90, 120, 180])
#
# Stored as a single jsonb column mirroring the existing loan_settings/operational_settings
# pattern. Company readers merge stored values over DEAL_DESK_SETTING_DEFAULTS.
class AddDealDeskSettingsToCompanies < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :deal_desk_settings, :jsonb, null: false, default: {}
  end
end
