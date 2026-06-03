# frozen_string_literal: true

# Separates the rep-typed manual APR override (apr_override) from the
# computed/resolved APR (apr). Resolves the recompute! collision where the
# resolved rate was re-read as a manual override on the next recompute.
class AddAprOverrideToDealDeskScenarios < ActiveRecord::Migration[8.0]
  def change
    add_column :deal_desk_scenarios, :apr_override, :decimal, precision: 6, scale: 3
  end
end
