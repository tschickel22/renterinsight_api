# frozen_string_literal: true

# A dealer's own texting registration (E96 phase 4): their business, the
# person who speaks for it, how buyers agree to texts, and each carrier stage
# (brand, campaign, number) with Twilio's ids, so one dealer's complaints never
# count against another's.
class CreateSmsRegistrations < ActiveRecord::Migration[8.0]
  def change
    create_table :sms_registrations do |t|
      t.bigint :company_id, null: false
      # draft, submitted (waiting for platform admin), in_review, approved,
      # live, rejected
      t.string :status, null: false, default: 'draft'
      # low_volume_standard, standard, sole_proprietor
      t.string :brand_type, null: false, default: 'low_volume_standard'
      t.jsonb :business, null: false, default: {}
      t.jsonb :contact, null: false, default: {}
      t.jsonb :consent, null: false, default: {}
      t.string :preferred_area_code
      t.string :customer_profile_sid
      t.string :end_user_sid
      t.string :address_sid
      t.string :trust_product_sid
      t.string :brand_registration_sid
      t.string :brand_status
      t.string :messaging_service_sid
      t.string :campaign_status
      t.string :campaign_id
      t.string :phone_number
      t.string :phone_number_sid
      t.text :rejection_reason
      t.jsonb :events, null: false, default: []
      t.bigint :submitted_by_user_id
      t.datetime :submitted_at
      t.datetime :sent_to_carriers_at
      t.datetime :approved_at
      t.datetime :live_at
      t.timestamps
    end
    add_index :sms_registrations, :company_id, unique: true
    add_index :sms_registrations, :status
  end
end
