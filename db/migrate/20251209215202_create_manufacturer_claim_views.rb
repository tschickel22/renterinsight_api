# frozen_string_literal: true

class CreateManufacturerClaimViews < ActiveRecord::Migration[8.0]
  def change
    create_table :manufacturer_claim_views do |t|
      t.references :warranty_claim, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.string :ip_address
      t.string :user_agent
      t.datetime :viewed_at, null: false

      t.timestamps
    end
    
    add_index :manufacturer_claim_views, [:warranty_claim_id, :viewed_at]
  end
end
