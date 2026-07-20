# frozen_string_literal: true

require 'rails_helper'

# Covers Issue #3: UserEmailConnection#needs_reauth? classifier + mark_needs_reauth!
# writes a notification. When a send fails with an OAuth auth-rejection pattern
# we want the connection flagged and the user notified — not silent failure.
RSpec.describe UserEmailConnection, '#needs_reauth? / #mark_needs_reauth!', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:connection) do
    UserEmailConnection.create!(
      user_id: user.id, provider: 'oauth_gmail', email_address: 'u@gmail.com',
      is_active: true, oauth_expires_at: 1.hour.from_now,
      oauth_token_encrypted: 'tok', oauth_refresh_token_encrypted: 'rtok'
    )
  end

  describe '#needs_reauth?' do
    it 'is false with no error recorded' do
      expect(connection.needs_reauth?).to eq(false)
    end

    it 'is true when last_error matches a Google XOAUTH2 challenge' do
      connection.record_error!('XOAUTH2 rejected — Bearer scope https://mail.google.com/ required')
      expect(connection.reload.needs_reauth?).to eq(true)
    end

    it 'is true for Microsoft InvalidAuthenticationToken' do
      connection.record_error!('InvalidAuthenticationToken: access token expired')
      expect(connection.reload.needs_reauth?).to eq(true)
    end

    it 'is false for a transient network error' do
      connection.record_error!('Connection timeout')
      expect(connection.reload.needs_reauth?).to eq(false)
    end
  end

  describe '#mark_needs_reauth!' do
    it 'records the error and creates a Notification for the owning user' do
      expect {
        connection.mark_needs_reauth!('XOAUTH2 rejected — bad Bearer scope')
      }.to change { Notification.where(recipient: user, notification_type: 'email_connection_broken').count }.by(1)

      connection.reload
      expect(connection.needs_reauth?).to eq(true)
      expect(connection.last_error_message).to include('Reauth required')

      note = Notification.where(recipient: user, notification_type: 'email_connection_broken').last
      expect(note.message).to include('Gmail')
      expect(note.message).to include('u@gmail.com')
    end
  end
end
