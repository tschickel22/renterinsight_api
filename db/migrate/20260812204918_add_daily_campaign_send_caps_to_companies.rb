class AddDailyCampaignSendCapsToCompanies < ActiveRecord::Migration[8.0]
  def change
    # Nullable on purpose: NULL means "use the platform default", so changing
    # that default later is a constant edit rather than a data migration across
    # every tenant that never had an opinion about it.
    add_column :companies, :daily_campaign_email_cap, :integer
    add_column :companies, :daily_campaign_sms_cap, :integer

    # The cap counts a tenant's sends so far today, on every send. Only
    # company_id was indexed, so that count scanned every send the tenant had
    # ever made rather than today's.
    add_index :campaign_sends, %i[company_id sent_at],
              name: 'index_campaign_sends_on_company_and_sent_at'
  end
end
