# frozen_string_literal: true

class AddAutoPostDealsToAccountingSettings < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:accounting_settings, :auto_post_deals)
      add_column :accounting_settings, :auto_post_deals, :boolean, default: false, null: false
    end
  end
end
