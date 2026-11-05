# frozen_string_literal: true

# HUD and modular homes from one plant carry different surcharges, so a rule can
# name which it covers. Not on production yet; 'any' keeps a rule covering both.
class AddBuildingCodeToDealerSurchargeRules < ActiveRecord::Migration[8.0]
  def change
    add_column :dealer_surcharge_rules, :building_code, :string, null: false, default: 'any'
    remove_index :dealer_surcharge_rules, name: 'idx_dealer_surcharge_rules_one_per_scope'
    add_index :dealer_surcharge_rules, 'company_id, manufacturer_id, COALESCE(factory_id, 0), building_code, section',
              unique: true, name: 'idx_dealer_surcharge_rules_one_per_scope'
  end
end
