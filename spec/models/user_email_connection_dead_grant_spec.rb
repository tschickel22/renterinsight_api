# frozen_string_literal: true

require 'rails_helper'

# A refresh token the provider has permanently rejected (invalid_grant, revoked
# consent, a testing-mode grant past its 7 day life) never recovers by being
# asked again. Before this, refresh_oauth_token! logged the rejection and
# returned nil, so the two 10-minute pollers re-posted the same doomed refresh
# forever: one stale Gmail mailbox on staging accounted for roughly 400 rejected
# token requests a day against the Google OAuth client, with nobody notified.
RSpec.describe UserEmailConnection, 'dead grant handling', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  def build_connection(provider: 'oauth_gmail')
    UserEmailConnection.create!(
      user_id: user.id, provider: provider, email_address: "u-#{SecureRandom.hex(3)}@gmail.com",
      is_active: true, oauth_expires_at: 1.hour.ago,
      oauth_token_encrypted: 'stale', oauth_refresh_token_encrypted: 'rtok'
    )
  end

  def stub_token_endpoint(body)
    allow(Net::HTTP).to receive(:start).and_return(double(body: body.to_json))
  end

  def broken_notifications
    Notification.where(recipient: user, notification_type: 'email_connection_broken')
  end

  describe '#refresh_oauth_token!' do
    it 'flags the connection and notifies the owner on invalid_grant' do
      connection = build_connection
      stub_token_endpoint('error' => 'invalid_grant', 'error_description' => 'Bad Request')

      expect { expect(connection.refresh_oauth_token!).to be_nil }
        .to change { broken_notifications.count }.by(1)

      connection.reload
      expect(connection.needs_reauth?).to eq(true)
      expect(connection.last_error_message).to include('invalid_grant')
    end

    it 'does not notify a second time while it is still flagged' do
      connection = build_connection
      stub_token_endpoint('error' => 'invalid_grant', 'error_description' => 'Bad Request')
      connection.refresh_oauth_token!

      expect { connection.refresh_oauth_token! }.not_to change { broken_notifications.count }
    end

    it 'leaves a transient provider error unflagged' do
      connection = build_connection
      stub_token_endpoint('error' => 'temporarily_unavailable', 'error_description' => 'Try again')

      expect { expect(connection.refresh_oauth_token!).to be_nil }
        .not_to change { broken_notifications.count }
      expect(connection.reload.needs_reauth?).to eq(false)
    end

    it 'clears nothing and stays unflagged on success' do
      connection = build_connection
      stub_token_endpoint('access_token' => 'fresh', 'expires_in' => 3600)

      expect(connection.refresh_oauth_token!).to eq('fresh')
      expect(connection.reload.needs_reauth?).to eq(false)
      expect(connection.oauth_expires_at).to be > Time.current
    end
  end

  describe '#ensure_graph_token!' do
    # Microsoft answers a scope the user never consented to with invalid_grant
    # too, and ensure_graph_token! deliberately asks for the wider Send+Read
    # grant before falling back to Send-only. Flagging on the first rejection
    # would tell a mailbox that sends perfectly well to reconnect.
    it 'does not flag when the wider scope is rejected but the fallback works' do
      connection = build_connection(provider: 'oauth_outlook')
      allow(connection).to receive(:refresh_oauth_token_for_graph_read!).and_return(nil)
      allow(connection).to receive(:refresh_oauth_token_for_graph!).and_return('send-only-token')

      expect { expect(connection.ensure_graph_token!).to eq('send-only-token') }
        .not_to change { broken_notifications.count }
      expect(connection.reload.needs_reauth?).to eq(false)
    end

    it 'flags when both scopes are rejected' do
      connection = build_connection(provider: 'oauth_outlook')
      stub_token_endpoint('error' => 'invalid_grant', 'error_description' => 'Bad Request')

      expect { connection.ensure_graph_token! }.to change { broken_notifications.count }.by(1)
      expect(connection.reload.needs_reauth?).to eq(true)
    end
  end
end
