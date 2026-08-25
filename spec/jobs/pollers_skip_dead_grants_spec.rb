# frozen_string_literal: true

require 'rails_helper'

# Both 10-minute pollers used to select on is_active alone, so a connection
# already flagged as needing reconnect kept being polled, and each poll posted a
# refresh the provider had already permanently rejected. Flagging is only half
# the fix; this is the half that stops the traffic.
RSpec.describe 'Email pollers skip connections awaiting reconnect', type: :job do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  def build_connection(error: nil)
    connection = UserEmailConnection.create!(
      user_id: user.id, provider: 'oauth_gmail', email_address: "u-#{SecureRandom.hex(3)}@gmail.com",
      is_active: true, oauth_expires_at: 1.hour.ago,
      oauth_token_encrypted: 'stale', oauth_refresh_token_encrypted: 'rtok',
      oauth_scopes: 'https://mail.google.com/ https://www.googleapis.com/auth/userinfo.email'
    )
    connection.record_error!(error) if error
    connection.reload
  end

  before do
    # Only the connections this spec creates should exist for the pollers.
    UserEmailConnection.delete_all
    User.where.not(email_username: nil).update_all(email_username: nil)
  end

  describe SyncAllUsersSentEmailsJob do
    it 'skips a connection flagged for reconnect' do
      build_connection(error: 'Reauth required: invalid_grant - Bad Request')

      expect(ImapSentEmailService).not_to receive(:sync_via_connection)
      described_class.perform_now
    end

    it 'still syncs a healthy connection' do
      connection = build_connection

      expect(ImapSentEmailService).to receive(:sync_via_connection)
        .with(having_attributes(id: connection.id), 30)
        .and_return({ success: true, synced_count: 0 })
      described_class.perform_now
    end
  end

  describe HarvestCampaignBouncesJob do
    it 'skips a connection flagged for reconnect' do
      build_connection(error: 'Reauth required: invalid_grant - Bad Request')

      expect(Campaigns::InboundBounceHarvester).not_to receive(:harvest_connection)
      described_class.perform_now
    end

    it 'still harvests a healthy connection' do
      connection = build_connection

      expect(Campaigns::InboundBounceHarvester).to receive(:harvest_connection)
        .with(having_attributes(id: connection.id), minutes_back: 30)
        .and_return(Campaigns::InboundBounceHarvester::Result.empty)
      described_class.perform_now
    end
  end
end
