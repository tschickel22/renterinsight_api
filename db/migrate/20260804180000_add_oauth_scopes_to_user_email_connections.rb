# frozen_string_literal: true

# Records what the provider actually granted, so behaviour is derived from the
# grant rather than assumed from the provider name.
#
# Until now "provider is oauth_gmail" was taken to mean "we have full mailbox
# access", because full access was the only thing we ever asked for. Narrowing
# the Gmail request to gmail.send breaks that assumption: the table would hold
# both old full-access connections and new send-only ones with nothing to tell
# them apart, so the IMAP pollers would keep trying send-only mailboxes, fail
# on auth, and (via EmailConnectionHealth) notify those users that a perfectly
# healthy mailbox had stopped sending.
#
# Google also returns what the user actually consented to, which can be less
# than was requested, so the granted set is worth storing regardless.
class AddOauthScopesToUserEmailConnections < ActiveRecord::Migration[8.0]
  # What each provider was historically asked for. Existing rows predate scope
  # capture, so backfill them with the grant they must have been given rather
  # than leaving NULL and relying on a convention to interpret it.
  LEGACY_GMAIL_SCOPES  = 'https://mail.google.com/ https://www.googleapis.com/auth/userinfo.email'
  LEGACY_OUTLOOK_SCOPES = 'offline_access https://graph.microsoft.com/Mail.Send ' \
                          'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read'

  def up
    add_column :user_email_connections, :oauth_scopes, :text

    execute(<<~SQL.squish)
      UPDATE user_email_connections
      SET oauth_scopes = #{connection.quote(LEGACY_GMAIL_SCOPES)}
      WHERE provider = 'oauth_gmail' AND oauth_scopes IS NULL
    SQL

    execute(<<~SQL.squish)
      UPDATE user_email_connections
      SET oauth_scopes = #{connection.quote(LEGACY_OUTLOOK_SCOPES)}
      WHERE provider = 'oauth_outlook' AND oauth_scopes IS NULL
    SQL
  end

  def down
    remove_column :user_email_connections, :oauth_scopes
  end
end
