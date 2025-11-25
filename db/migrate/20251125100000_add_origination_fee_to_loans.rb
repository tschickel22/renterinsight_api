# frozen_string_literal: true

class AddOriginationFeeToLoans < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:loans, :origination_fee)
      add_column :loans, :origination_fee, :decimal, precision: 10, scale: 2, default: 0.0
    end
  end
end
