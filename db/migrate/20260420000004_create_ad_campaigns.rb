# frozen_string_literal: true

class CreateAdCampaigns < ActiveRecord::Migration[8.0]
  def change
    create_table :ad_campaigns do |t|
      t.bigint  :company_id, null: false
      t.string  :external_campaign_id, null: false
      t.string  :name
      t.string  :objective
      t.string  :status

      t.decimal :daily_budget,    precision: 12, scale: 2
      t.decimal :lifetime_budget, precision: 12, scale: 2

      t.decimal :spend,       precision: 12, scale: 2, default: 0
      t.integer :impressions, default: 0
      t.integer :clicks,      default: 0
      t.integer :reach,       default: 0

      t.integer :leads_count, default: 0
      t.integer :deals_count, default: 0
      t.decimal :revenue,     precision: 12, scale: 2, default: 0

      t.decimal :cost_per_lead, precision: 10, scale: 2, default: 0
      t.decimal :cost_per_deal, precision: 10, scale: 2, default: 0
      t.decimal :roi_percentage, precision: 10, scale: 2, default: 0

      t.datetime :synced_at
      t.boolean  :is_deleted, default: false

      t.timestamps
    end

    add_index :ad_campaigns, [:company_id, :external_campaign_id], unique: true
    add_index :ad_campaigns, [:company_id, :status]
  end
end
