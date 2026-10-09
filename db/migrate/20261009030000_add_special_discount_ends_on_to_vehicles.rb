# frozen_string_literal: true

# A home's sale (its special discount) can end on a date (backlog E72): the
# day after, the discount turns off, the sale price stops showing on the
# website, listings and feeds, and the home shows its base price again.
class AddSpecialDiscountEndsOnToVehicles < ActiveRecord::Migration[8.0]
  def change
    add_column :vehicles, :special_discount_ends_on, :date
    add_index :vehicles, :special_discount_ends_on, where: 'special_discount_enabled'
  end
end
