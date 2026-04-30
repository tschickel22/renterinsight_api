class AddSmsPhoneSnapshotToCampaignEnrollments < ActiveRecord::Migration[8.0]
  def change
    add_column :campaign_enrollments, :sms_phone_snapshot, :string
    change_column_null :campaign_enrollments, :email_address_snapshot, true
  end
end
