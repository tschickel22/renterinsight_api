# frozen_string_literal: true

require 'rails_helper'

# One revoked Microsoft grant sent its owner three "reconnect" notices in ten
# minutes. Two came from the sent-mail sync and the bounce harvester flagging
# the same connection in the same second. The third came after the harvester
# wrote its Graph 401 over the flag, which un-flagged the connection so the
# next poll treated it as newly broken.
RSpec.describe UserEmailConnection, 'reconnect notice dedupe', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let!(:connection) do
    UserEmailConnection.create!(
      user_id: user.id, provider: 'oauth_outlook', email_address: "u-#{SecureRandom.hex(3)}@example.com",
      is_active: true, oauth_expires_at: 1.hour.ago,
      oauth_token_encrypted: 'stale', oauth_refresh_token_encrypted: 'rtok'
    )
  end

  def broken_notifications
    Notification.where(recipient: user, notification_type: 'email_connection_broken')
  end

  it 'notifies once when two jobs flag the same connection at the same moment' do
    sync_job_copy = UserEmailConnection.find(connection.id)
    harvester_copy = UserEmailConnection.find(connection.id)

    expect {
      EmailConnectionHealth.flag!(sync_job_copy, 'invalid_grant - AADSTS50173')
      EmailConnectionHealth.flag!(harvester_copy, 'invalid_grant - AADSTS50173')
    }.to change { broken_notifications.count }.by(1)

    expect(harvester_copy.needs_reauth?).to be true
  end

  it 'keeps the flag when a job holding an older copy records an ordinary error' do
    stale_copy = UserEmailConnection.find(connection.id)
    EmailConnectionHealth.flag!(connection, 'invalid_grant')

    expect(stale_copy.record_error!('Graph inbox error 401')).to be false
    expect(connection.reload.needs_reauth?).to be true
    expect { EmailConnectionHealth.flag!(connection, 'invalid_grant') }.not_to change { broken_notifications.count }
  end

  it 'still records ordinary errors on a connection that is not flagged' do
    connection.record_error!('Connection timeout')
    expect(connection.reload.last_error_message).to eq('Connection timeout')
  end

  it 'notifies again after a reconnect clears the flag' do
    EmailConnectionHealth.flag!(connection, 'invalid_grant')
    connection.update!(last_error_at: nil, last_error_message: nil)

    expect { EmailConnectionHealth.flag!(connection.reload, 'invalid_grant') }
      .to change { broken_notifications.count }.by(1)
  end
end
