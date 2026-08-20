# frozen_string_literal: true

# Biometric unlock was staff-only because this table was.
#
# Customers and contractors are the audiences that need it most: a rep signs in
# daily and has muscle memory for their password, while a customer signs in a
# handful of times across a purchase, months apart, and is exactly the person
# who has forgotten it. PushSubscription already carries a polymorphic owner for
# the same reason; this brings device sessions into line.
class MakeDeviceSessionsPolymorphic < ActiveRecord::Migration[8.0]
  def up
    add_column :device_sessions, :owner_type, :string
    add_column :device_sessions, :owner_id, :bigint

    # Every existing row is a staff enrolment, by definition.
    execute <<~SQL
      UPDATE device_sessions
      SET owner_type = 'User', owner_id = user_id
      WHERE owner_id IS NULL AND user_id IS NOT NULL
    SQL

    # Anything without a user_id could never have been authenticated against.
    execute 'DELETE FROM device_sessions WHERE owner_id IS NULL'

    change_column_null :device_sessions, :owner_type, false
    change_column_null :device_sessions, :owner_id, false

    add_index :device_sessions, [:owner_type, :owner_id, :revoked_at],
              name: 'index_device_sessions_on_owner_and_revoked'

    remove_index :device_sessions, column: [:user_id, :revoked_at] if index_exists?(:device_sessions, [:user_id, :revoked_at])
    remove_column :device_sessions, :user_id
  end

  def down
    add_column :device_sessions, :user_id, :bigint

    execute <<~SQL
      UPDATE device_sessions SET user_id = owner_id WHERE owner_type = 'User'
    SQL

    # Portal and contractor sessions cannot be represented by a user_id, and a
    # dangling row would authenticate as nobody.
    execute "DELETE FROM device_sessions WHERE owner_type <> 'User'"

    add_index :device_sessions, [:user_id, :revoked_at]
    remove_index :device_sessions, name: 'index_device_sessions_on_owner_and_revoked'
    remove_column :device_sessions, :owner_type
    remove_column :device_sessions, :owner_id
  end
end
