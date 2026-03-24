class AddDiscountAndTotalColumnsToDeals < ActiveRecord::Migration[7.1]
  def change
    cols = {
      dealer_discount: [:decimal, { precision: 15, scale: 2, default: 0 }],
      sales_event_discount: [:decimal, { precision: 15, scale: 2, default: 0 }],
      manager_discount: [:decimal, { precision: 15, scale: 2, default: 0 }],
      preferred_payment_discount: [:decimal, { precision: 15, scale: 2, default: 0 }],
      multi_unit_discount: [:decimal, { precision: 15, scale: 2, default: 0 }],
      subtotal_1: [:decimal, { precision: 15, scale: 2, default: 0 }],
      subtotal_2: [:decimal, { precision: 15, scale: 2, default: 0 }],
      tax_amount: [:decimal, { precision: 15, scale: 2, default: 0 }],
      total_amount: [:decimal, { precision: 15, scale: 2, default: 0 }],
      down_payment: [:decimal, { precision: 15, scale: 2, default: 0 }],
      additional_payment: [:decimal, { precision: 15, scale: 2, default: 0 }],
      unpaid_balance: [:decimal, { precision: 15, scale: 2, default: 0 }],
    }

    cols.each do |col_name, (col_type, options)|
      unless column_exists?(:deals, col_name)
        add_column :deals, col_name, col_type, **options
      end
    end
  end
end
