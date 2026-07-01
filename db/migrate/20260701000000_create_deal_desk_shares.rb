# frozen_string_literal: true

# Public-token share for one or more Deal Desk scenarios. When a rep hits
# "Share" in the desk we snapshot the picked scenarios (customer-view masked)
# + the deal's vehicle brochure payload into `snapshot`, mint a short public
# token, and send the resulting `/q/desk/<token>` URL via SMS/email.
#
# Design notes:
# * `snapshot` is frozen at send time — customers see exactly what was sent,
#   even if the rep edits the scenarios afterward.
# * Public-view masking is enforced server-side inside the snapshot builder,
#   never trusted from the client.
# * Pattern mirrors Brochure's `public_id` + `SecureRandom.urlsafe_base64(12)`.
class CreateDealDeskShares < ActiveRecord::Migration[8.0]
  def change
    create_table :deal_desk_shares do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :deal,    null: false, foreign_key: true, index: true
      t.references :shared_by, foreign_key: { to_table: :users }, index: true

      t.string  :public_token, null: false, limit: 24
      t.jsonb   :scenario_ids, null: false, default: []
      t.jsonb   :snapshot,     null: false, default: {}

      t.string  :channels,   null: false, default: [], array: true
      t.string  :to_email
      t.string  :to_phone
      t.text    :custom_message

      t.datetime :sent_at
      t.datetime :first_viewed_at
      t.datetime :last_viewed_at
      t.datetime :expires_at
      t.integer  :view_count, null: false, default: 0

      t.jsonb :send_results, default: {}

      t.timestamps
    end

    add_index :deal_desk_shares, :public_token, unique: true
    add_index :deal_desk_shares, :expires_at
  end
end
