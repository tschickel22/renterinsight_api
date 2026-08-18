class CreatePushSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :push_subscriptions do |t|
      # Polymorphic owner: User (staff app) or BuyerPortalAccess (customer portal app)
      t.string  :owner_type, null: false
      t.bigint  :owner_id,   null: false

      t.bigint  :company_id

      # Which native app the device is running. Each has its own OneSignal app,
      # so a player id is only meaningful alongside this.
      t.string  :app, null: false, default: 'staff'

      # OneSignal subscription id (the "player id" the Natively bridge returns)
      t.string  :player_id, null: false

      # The alias we push to. Stable per owner, so a user with three devices is
      # one target instead of three sends.
      t.string  :external_id

      t.string  :platform          # ios / android / web
      t.string  :device_model
      t.string  :app_version
      t.string  :natively_version

      # OS-level permission as last reported by the device. False means the
      # device is registered but the user has push switched off in Settings.
      t.boolean :permission_granted, null: false, default: true

      t.datetime :last_seen_at
      t.datetime :last_success_at
      t.datetime :revoked_at
      t.integer  :failure_count, null: false, default: 0
      t.string   :last_error

      t.timestamps
    end

    add_index :push_subscriptions, :player_id, unique: true
    add_index :push_subscriptions, [:owner_type, :owner_id]
    add_index :push_subscriptions, [:app, :external_id]
    add_index :push_subscriptions, :company_id
    add_index :push_subscriptions, :revoked_at
  end
end
