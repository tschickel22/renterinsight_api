class CreateCampaignEnrollments < ActiveRecord::Migration[8.0]
  def change
    create_table :campaign_enrollments do |t|
      t.bigint :company_id, null: false
      t.bigint :campaign_id, null: false
      t.string :recipient_type, null: false
      t.bigint :recipient_id, null: false
      t.string :email_address_snapshot, null: false
      t.string :status, null: false, default: 'pending'
      t.integer :current_step_index, default: 0, null: false
      t.datetime :next_send_at
      t.datetime :last_sent_at
      t.datetime :goal_met_at
      t.string :goal_met_reason
      t.datetime :unsubscribed_at
      t.datetime :bounced_at
      t.datetime :complained_at
      t.string :failure_reason
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end
    add_index :campaign_enrollments, [:campaign_id, :status, :next_send_at], name: 'idx_campaign_enrollments_due'
    add_index :campaign_enrollments, [:recipient_type, :recipient_id]
    add_index :campaign_enrollments, [:campaign_id, :recipient_type, :recipient_id], unique: true, name: 'idx_campaign_enrollments_unique'
    add_index :campaign_enrollments, :company_id
    add_foreign_key :campaign_enrollments, :campaigns
  end
end
