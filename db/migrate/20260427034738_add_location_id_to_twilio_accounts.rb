class AddLocationIdToTwilioAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :twilio_accounts, :location_id, :bigint
    add_index :twilio_accounts, [:company_id, :location_id]
  end
end
