# frozen_string_literal: true

# The people at a vendor. A vendor row holds one contact_name/email/phone, which
# is fine for a one-person installer and wrong for a lender or a factory with a
# dozen reps (Easy Homesource has 17 people at MHI alone). Each person gets a row
# here, and receives_project_notices picks who project emails and texts go to.
#
# Additive only. A vendor with no contacts keeps sending to its own email and
# phone, so code already running during the release behaves exactly as before.
class CreateVendorContacts < ActiveRecord::Migration[8.0]
  def change
    create_table :vendor_contacts do |t|
      t.references :company, null: false, index: true
      t.references :vendor, null: false, index: true
      t.string :first_name
      t.string :last_name
      t.string :title
      t.string :email
      t.string :phone
      t.string :priority
      t.text :notes
      t.boolean :is_primary, null: false, default: false
      t.boolean :receives_project_notices, null: false, default: false
      t.boolean :sms_opt_in, null: false, default: false
      t.string :sms_consent_source
      t.datetime :sms_consent_recorded_at
      t.bigint :sms_consent_recorded_by_id
      t.text :sms_consent_note
      t.boolean :is_deleted, null: false, default: false
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :vendor_contacts, [:vendor_id, :is_deleted]
  end
end
