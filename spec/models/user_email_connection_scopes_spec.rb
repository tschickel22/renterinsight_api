# frozen_string_literal: true

require 'rails_helper'

# Capabilities must come from the grant, never from the provider name. Once
# Gmail is requested as gmail.send, the table holds both full-access and
# send-only connections with the same provider value, and the pollers have to
# tell them apart.
RSpec.describe UserEmailConnection, 'granted capabilities', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  def connection(provider:, scopes:)
    UserEmailConnection.create!(
      user_id: user.id, provider: provider, email_address: "c-#{SecureRandom.hex(3)}@example.com",
      is_active: true, verified_at: Time.current, oauth_scopes: scopes,
      oauth_token_encrypted: 'tok', oauth_refresh_token_encrypted: 'rtok',
      smtp_host: provider == 'smtp' ? 'smtp.gmail.com' : nil,
      smtp_username: provider == 'smtp' ? 'u@gmail.com' : nil,
      smtp_password_encrypted: provider == 'smtp' ? 'pw' : nil
    )
  end

  describe '#can_read_mailbox?' do
    it 'is true for the full Gmail grant' do
      c = connection(provider: 'oauth_gmail', scopes: 'https://mail.google.com/ https://www.googleapis.com/auth/userinfo.email')
      expect(c.can_read_mailbox?).to be true
    end

    it 'is false for a send-only Gmail grant' do
      c = connection(provider: 'oauth_gmail',
                     scopes: 'https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/userinfo.email')
      expect(c.can_read_mailbox?).to be false
    end

    it 'is true for gmail.readonly' do
      c = connection(provider: 'oauth_gmail', scopes: 'https://www.googleapis.com/auth/gmail.readonly')
      expect(c.can_read_mailbox?).to be true
    end

    it 'is true for the Microsoft Mail.Read grant' do
      c = connection(provider: 'oauth_outlook',
                     scopes: 'offline_access https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/Mail.Read')
      expect(c.can_read_mailbox?).to be true
    end

    it 'is false for a Microsoft grant that can only send' do
      c = connection(provider: 'oauth_outlook',
                     scopes: 'offline_access https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/User.Read')
      expect(c.can_read_mailbox?).to be false
    end

    # A row written before scope capture existed can only have been granted the
    # full access that was requested back then. Treating a blank grant as
    # send-only would switch off a poller that has been working for months.
    it 'treats a blank grant on an OAuth connection as legacy full access' do
      c = connection(provider: 'oauth_gmail', scopes: nil)
      expect(c.can_read_mailbox?).to be true
    end

    it 'is true for password-based connections, which authenticate to IMAP directly' do
      c = connection(provider: 'smtp', scopes: nil)
      expect(c.can_read_mailbox?).to be true
    end
  end

  describe '#requires_rest_send?' do
    # IMAP and SMTP over XOAUTH2 both need the full mailbox grant, so a
    # send-only connection has to go over the REST API.
    it 'is true for a send-only Gmail grant' do
      c = connection(provider: 'oauth_gmail', scopes: 'https://www.googleapis.com/auth/gmail.send')
      expect(c.requires_rest_send?).to be true
    end

    it 'is false for a full grant' do
      c = connection(provider: 'oauth_gmail', scopes: 'https://mail.google.com/')
      expect(c.requires_rest_send?).to be false
    end

    it 'is false for password-based connections' do
      c = connection(provider: 'smtp', scopes: nil)
      expect(c.requires_rest_send?).to be false
    end
  end

  # Ties the scope we actually request to the behaviour that depends on it. If
  # someone widens or narrows GOOGLE_OAUTH_SCOPES without thinking about the
  # pollers or the send transport, this is what tells them.
  describe 'the scopes we request' do
    it 'yields a send-only Gmail connection' do
      c = connection(provider: 'oauth_gmail', scopes: Api::V1::OauthEmailController::GOOGLE_OAUTH_SCOPES)

      expect(c.can_read_mailbox?).to be false
      expect(c.requires_rest_send?).to be true
    end

    it 'yields a readable Outlook connection, so Graph sync keeps working' do
      c = connection(provider: 'oauth_outlook', scopes: Api::V1::OauthEmailController::MICROSOFT_OAUTH_SCOPES)

      expect(c.can_read_mailbox?).to be true
      expect(c.requires_rest_send?).to be false
    end
  end

  describe '#granted_scopes' do
    it 'splits on whitespace and drops blanks' do
      c = connection(provider: 'oauth_gmail', scopes: "  https://mail.google.com/   https://www.googleapis.com/auth/userinfo.email ")
      expect(c.granted_scopes).to eq(
        ['https://mail.google.com/', 'https://www.googleapis.com/auth/userinfo.email']
      )
    end

    it 'is empty when nothing was recorded' do
      expect(connection(provider: 'oauth_gmail', scopes: nil).granted_scopes).to eq([])
    end
  end
end
