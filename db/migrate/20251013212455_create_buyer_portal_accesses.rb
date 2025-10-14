class CreateBuyerPortalAccesses < ActiveRecord::Migration[7.0]
  def change
    create_table :buyer_portal_accesses do |t|
      t.references :buyer, polymorphic: true, null: false, index: true
      t.string :email, null: false, index: { unique: true }
      t.string :password_digest
      t.string :reset_token, index: true
      t.datetime :reset_token_expires_at
      t.string :login_token, index: true
      t.datetime :login_token_expires_at
      t.datetime :last_login_at
      t.integer :login_count, default: 0
      t.string :last_login_ip
      t.boolean :portal_enabled, default: true
      t.boolean :email_opt_in, default: true
      t.boolean :sms_opt_in, default: true
      t.boolean :marketing_opt_in, default: false
      t.text :preference_history
      t.timestamps
    end
  end
end
