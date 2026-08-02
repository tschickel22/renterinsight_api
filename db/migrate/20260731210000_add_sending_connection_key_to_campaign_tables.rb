class AddSendingConnectionKeyToCampaignTables < ActiveRecord::Migration[8.0]
  # Rate limiting has to be measured per sending mailbox, not per campaign.
  # Two campaigns pointed at the same mailbox each got their own throttle_per_day
  # budget, so the mailbox absorbed both and Microsoft restricted it.
  #
  # The key is denormalized onto both tables rather than joined through
  # campaigns.from_identity_* because Owner-mode campaigns resolve a DIFFERENT
  # mailbox per recipient (Campaign#resolve_owner_email_connection), which a
  # join on the campaign row cannot express.
  #
  # enrollments: used to allocate send slots at scheduling time.
  # sends:       used to count actuals in the trailing rate windows.
  def change
    add_column :campaign_enrollments, :sending_connection_key, :string
    add_column :campaign_sends, :sending_connection_key, :string

    add_index :campaign_enrollments, %i[sending_connection_key next_send_at],
              name: 'idx_campaign_enrollments_connection_slot'
    add_index :campaign_sends, %i[sending_connection_key sent_at],
              name: 'idx_campaign_sends_connection_rate'
  end
end
