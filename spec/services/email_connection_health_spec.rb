# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmailConnectionHealth do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:connection) do
    UserEmailConnection.create!(
      user_id: user.id, provider: 'oauth_gmail', email_address: 'rep@example.com',
      is_active: true, verified_at: Time.current, oauth_expires_at: 1.hour.from_now,
      oauth_token_encrypted: 'tok', oauth_refresh_token_encrypted: 'rtok'
    )
  end

  describe '.flag!' do
    it 'flags a dead token and notifies the owner' do
      expect(described_class.flag!(connection, 'invalid_grant: Token has been expired or revoked')).to be true
      expect(connection.reload.needs_reauth?).to be true
    end

    it 'accepts an exception as well as a string' do
      expect(described_class.flag!(connection, StandardError.new('invalid_grant'))).to be true
      expect(connection.reload.needs_reauth?).to be true
    end

    # A bad recipient or a rate limit must not nag the rep to reconnect a
    # mailbox that is working fine.
    it 'ignores ordinary send failures' do
      expect(described_class.flag!(connection, 'Recipient address rejected')).to be false
      expect(connection.reload.needs_reauth?).to be false
    end

    it 'ignores a blank error' do
      expect(described_class.flag!(connection, nil)).to be false
    end

    it 'does not re-notify a connection already flagged' do
      described_class.flag!(connection, 'invalid_grant')
      expect(described_class.flag!(connection.reload, 'invalid_grant')).to be false
    end

    it 'tolerates a nil connection' do
      expect(described_class.flag!(nil, 'invalid_grant')).to be false
    end
  end

  describe '.flag_from_config!' do
    let(:config) do
      { '_sourceConnectionType' => 'UserEmailConnection', '_sourceConnectionId' => connection.id }
    end

    it 'resolves the connection from the config hash' do
      expect(described_class.flag_from_config!(config, StandardError.new('invalid_grant'))).to be true
      expect(connection.reload.needs_reauth?).to be true
    end

    it 'works with symbol keys' do
      symbol_config = { _sourceConnectionType: 'UserEmailConnection', _sourceConnectionId: connection.id }
      expect(described_class.flag_from_config!(symbol_config, 'invalid_grant')).to be true
    end

    it 'ignores a config with no source connection' do
      expect(described_class.flag_from_config!({ 'provider' => 'aws_ses' }, 'invalid_grant')).to be false
    end

    it 'ignores a non-hash config' do
      expect(described_class.flag_from_config!(nil, 'invalid_grant')).to be false
    end
  end

  describe '.flag_for_user!' do
    it 'flags the mailbox the user would have sent from' do
      connection
      expect(described_class.flag_for_user!(user, StandardError.new('invalid_grant'))).to be true
      expect(connection.reload.needs_reauth?).to be true
    end

    it 'is a no-op for a user with no connection' do
      other = User.create!(email: "n-#{SecureRandom.hex(4)}@example.com", first_name: 'N', last_name: 'C',
                           password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
      expect(described_class.flag_for_user!(other, 'invalid_grant')).to be false
    end

    it 'tolerates nil' do
      expect(described_class.flag_for_user!(nil, 'invalid_grant')).to be false
    end
  end

  # The rule: a mailbox the rep connected on purpose, which has since broken,
  # must never be swapped for the company or platform sender. Falling back
  # would look like success while sending as the wrong person, and the rep
  # would never learn the connection was dead.
  describe 'a broken connection is not silently replaced by the waterfall' do
    it 'stays selected so the send fails attributably' do
      described_class.flag!(connection, 'invalid_grant')
      connection.reload

      expect(connection.needs_reauth?).to be true
      # Still the user's default and still active, which is what keeps the
      # resolvers pointed at it instead of falling through.
      expect(connection.is_active).to be true
      expect(user.default_email_connection).to eq(connection)
    end

    it 'is never deactivated as a side effect of being flagged' do
      expect { described_class.flag!(connection, 'invalid_grant') }
        .not_to change { connection.reload.is_active }
    end
  end
end
