class CreatePlayInstallations < ActiveRecord::Migration[8.0]
  # A starter play turned on for a company: what the dealer answered and every
  # record it created, so turning it off touches exactly those records.
  def change
    create_table :play_installations do |t|
      t.bigint :company_id, null: false
      t.string :play_key, null: false
      t.string :status, null: false, default: 'active'
      t.jsonb :answers, null: false, default: {}
      t.jsonb :assets, null: false, default: {}
      t.bigint :installed_by_user_id
      t.datetime :installed_at
      t.datetime :uninstalled_at
      t.timestamps
    end

    add_index :play_installations, [:company_id, :play_key]
    add_index :play_installations, [:company_id, :play_key], unique: true, where: "status = 'active'",
              name: 'idx_play_installations_one_active_per_play'
  end
end
