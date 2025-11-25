# frozen_string_literal: true

class AllowNullPaymentMethodInPayments < ActiveRecord::Migration[8.0]
  def change
    change_column_null :payments, :payment_method_id, true
  end
end
