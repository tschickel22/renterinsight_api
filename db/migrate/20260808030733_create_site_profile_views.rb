class CreateSiteProfileViews < ActiveRecord::Migration[8.0]
  # Whether a prospect actually opened the demo we sent them.
  #
  # A separate table rather than PageVisit, which belongs to a WebsitePage. A
  # demo preview is not a page of anyone's site: it is a token-addressed view of
  # a SiteContentProfile, rendered from a projection that never becomes rows
  # until someone commits it. There is nothing for a PageVisit to point at.
  #
  # One row per session, not per view, because the question is "did they come
  # back" and that only reads cleanly if a session is a single row that gets
  # touched. templates_viewed accumulates on that row so which design held their
  # attention needs no second table and no join to answer.
  def change
    create_table :site_profile_views do |t|
      t.references :site_content_profile, null: false, foreign_key: true, index: true

      # Durable identity across sessions, and the per-tab session. Mirrors the
      # split the dealer-site beacon already uses, so a returning prospect is
      # recognisable as the same person rather than as new traffic.
      t.string :visitor_token, null: false
      t.string :session_token, null: false

      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.integer :view_events, null: false, default: 0

      # { "<template_id>" => count }. A tally rather than rows: the report ranks
      # designs, and ranking is the only thing anyone asks of it.
      t.jsonb :templates_viewed, null: false, default: {}

      t.string :referrer
      t.string :device_type
      # Hashed, never the address itself. This is a prospect who has not agreed
      # to anything, and a rough sense of "same person" is all the report needs.
      t.string :ip_hash

      # Us opening our own demo to check it. Counted separately rather than
      # dropped, so a rep can tell "the prospect never opened it" from "nobody
      # opened it", which are different conversations.
      t.boolean :is_internal, null: false, default: false

      t.timestamps
    end

    # The beacon finds or creates by session on every call, so this is the hot
    # path and it has to be unique: two beacons racing on first paint would
    # otherwise write the session twice and double every count.
    add_index :site_profile_views, %i[site_content_profile_id session_token], unique: true,
                                                                              name: 'idx_profile_views_session'
    add_index :site_profile_views, %i[site_content_profile_id visitor_token]
  end
end
