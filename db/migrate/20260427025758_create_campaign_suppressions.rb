class CreateCampaignSuppressions < ActiveRecord::Migration[8.0]
  def change
    create_table :campaign_suppressions do |t|
      t.bigint :company_id, null: false
      t.string :email_address, null: false
      t.string :reason, null: false
      t.bigint :source_campaign_id
      t.datetime :suppressed_at, null: false
      t.text :notes
      t.timestamps
    end
    add_index :campaign_suppressions, [:company_id, :email_address], unique: true
  end
end
