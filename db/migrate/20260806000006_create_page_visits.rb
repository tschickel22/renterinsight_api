# frozen_string_literal: true

# Visitor tracking for landing pages.
#
# Nothing like this existed anywhere in the schema — no page-view, visit or
# visitor table. Campaign engagement was only ever measured at the email
# (opens, clicks); what happened after the click was invisible.
#
# Two tables rather than one: a visit is a session with identity and
# attribution attached, and events are the many things that happen inside it.
# Folding them together would either lose the per-event detail or repeat the
# attribution columns on every scroll milestone.
class CreatePageVisits < ActiveRecord::Migration[8.0]
  def change
    create_table :page_visits do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :website_page, null: false, foreign_key: true, index: true

      # Minted client-side, not by us.
      #
      # Public::SitesController serves pages through a 5-minute edge cache and
      # deletes Set-Cookie from every response (strip_session_cookie). A
      # per-visitor cookie set at the origin would both be stripped and make the
      # HTML uncacheable — poisoning the cache for everyone to identify one
      # person.
      t.string :visitor_token, null: false
      t.string :session_token, null: false

      t.string :referrer
      t.string :utm_source
      t.string :utm_medium
      t.string :utm_campaign
      t.string :utm_content
      t.string :utm_term

      # How a known recipient arrived. Set when the visit carries a campaign
      # link token, which already resolves to an enrollment and therefore to a
      # Lead / Contact / Account.
      t.references :campaign, null: true, foreign_key: true, index: true
      t.bigint :campaign_enrollment_id, index: true

      # Who this turned out to be. Back-stamped onto earlier anonymous visits
      # from the same visitor_token when a form submission identifies them, so
      # the whole pre-identification session is attributed rather than only the
      # page they finally converted on.
      t.string :identified_entity_type
      t.bigint :identified_entity_id
      t.datetime :identified_at

      t.string :device_type
      t.string :country
      # Hashed, never raw. An IP is personal data and nothing here needs to
      # reverse it — only to tell two visitors apart.
      t.string :ip_hash

      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.integer :duration_ms, default: 0, null: false
      t.integer :max_scroll_depth, default: 0, null: false
      t.boolean :converted, default: false, null: false

      # A crawler that renders JS inflates every number on the page. Flagged
      # rather than dropped, so the filtering is visible and reversible.
      t.boolean :is_bot, default: false, null: false

      t.timestamps
    end

    # The two hot reads: a page's visits over time, and every visit belonging to
    # one visitor (which is what back-stamping walks).
    add_index :page_visits, %i[website_page_id first_seen_at]
    add_index :page_visits, %i[company_id visitor_token]
    add_index :page_visits, %i[identified_entity_type identified_entity_id],
              name: 'index_page_visits_on_identified_entity'
    # One row per session per page. The beacon fires repeatedly through a
    # session; without this each scroll milestone could open a new visit.
    add_index :page_visits, %i[session_token website_page_id], unique: true

    create_table :page_visit_events do |t|
      t.references :page_visit, null: false, foreign_key: true, index: true
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :payload, default: {}, null: false

      t.timestamps
    end

    add_index :page_visit_events, %i[page_visit_id event_type]
    add_index :page_visit_events, :occurred_at
  end
end
