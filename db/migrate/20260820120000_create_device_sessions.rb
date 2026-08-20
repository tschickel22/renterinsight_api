# frozen_string_literal: true

# One row per phone a user has enabled biometric unlock on.
#
# The alternative was storing the password in the device Keychain, which is what
# the Natively biometrics API offers by default. A password cannot be revoked
# without changing it everywhere, so a lost phone would mean a password reset.
# A token can be revoked from a list, which is the whole reason this table
# exists rather than nothing.
class CreateDeviceSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :device_sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.bigint :company_id

      # Only the digest is stored. A leaked database should not hand anyone a
      # working session, the same reason password_digest exists.
      t.string :token_digest, null: false
      t.string :device_label
      t.string :platform
      t.string :app_version
      # Ties a session to the phone it was created on, so revoking biometric
      # unlock and revoking push for the same device can be reasoned about
      # together.
      t.string :player_id

      t.datetime :expires_at, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.string :revoked_reason
      t.integer :use_count, null: false, default: 0

      t.timestamps
    end

    add_index :device_sessions, :token_digest, unique: true
    add_index :device_sessions, [:user_id, :revoked_at]
    add_index :device_sessions, :expires_at
  end
end
