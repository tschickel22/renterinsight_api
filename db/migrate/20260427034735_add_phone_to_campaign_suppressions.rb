class AddPhoneToCampaignSuppressions < ActiveRecord::Migration[8.0]
  def change
    add_column :campaign_suppressions, :phone_number, :string

    begin
      remove_index :campaign_suppressions, name: 'index_campaign_suppressions_on_company_id_and_email_address'
    rescue ArgumentError
      # already gone
    end

    add_index :campaign_suppressions, [:company_id, :email_address],
              unique: true,
              where: 'email_address IS NOT NULL',
              name: 'idx_campaign_suppressions_email_unique'

    add_index :campaign_suppressions, [:company_id, :phone_number],
              unique: true,
              where: 'phone_number IS NOT NULL',
              name: 'idx_campaign_suppressions_phone_unique'

    change_column_null :campaign_suppressions, :email_address, true
  end
end
