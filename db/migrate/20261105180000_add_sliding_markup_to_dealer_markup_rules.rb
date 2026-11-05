# frozen_string_literal: true

# A markup that takes a smaller share as a home costs more, with a minimum in
# dollars. Nullable and unused by existing rules, so safe beside running code.
class AddSlidingMarkupToDealerMarkupRules < ActiveRecord::Migration[8.0]
  def change
    add_column :dealer_markup_rules, :sliding_multiplier, :decimal, precision: 12, scale: 4
    add_column :dealer_markup_rules, :sliding_curve, :decimal, precision: 8, scale: 4
    add_column :dealer_markup_rules, :minimum_markup, :decimal, precision: 12, scale: 2
  end
end
