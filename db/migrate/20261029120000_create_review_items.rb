# frozen_string_literal: true

# E87: Review Updates becomes the one place for project work waiting on
# someone. Each row is something a dealer or installer has to approve, answer or
# at least see; it closes when the thing it points at is dealt with, wherever
# that happens, so the list never goes stale.
#
# Also the small columns the E68 test-run fixes need: a note sent with a bid
# award, the record of staff changing a contractor's own bid, and the phase a
# bill is for.
class CreateReviewItems < ActiveRecord::Migration[8.0]
  def change
    create_table :review_items do |t|
      t.references :company, null: false, index: false
      t.references :project, index: true
      t.references :project_phase, index: false
      # What kind of thing it is (ReviewItem::KINDS).
      t.string :kind, null: false
      # The record it is about: a bill, bid, change order, job...
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      # Approvals and answers count on the badge; FYI items do not.
      t.boolean :needs_action, null: false, default: true
      t.string :status, null: false, default: 'open'
      t.string :title, null: false
      t.text :detail
      # Who it came from, as shown on the row ("Schick MH Install").
      t.string :from_name
      # Page in the app that deals with it.
      t.string :link
      # Blank means anyone in the company who can see projects.
      t.bigint :assigned_user_id
      t.string :resolution
      t.bigint :resolved_by_id
      t.string :resolved_by_name
      t.datetime :resolved_at
      t.datetime :nudged_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :review_items, %i[company_id status needs_action]
    add_index :review_items, %i[subject_type subject_id]
    add_index :review_items, %i[company_id assigned_user_id status]
    # One open item per thing; a repeat event refreshes it.
    add_index :review_items, %i[company_id kind subject_type subject_id], unique: true,
              where: "status = 'open'", name: 'index_review_items_one_open_per_subject'

    add_column :project_bid_requests, :award_note, :text
    # Staff changes to a bid the contractor entered: [{at, by_id, by_name, from, to, reason}]
    add_column :project_bids, :history, :jsonb, null: false, default: []

    add_column :bills, :project_phase_id, :bigint
    add_index :bills, :project_phase_id
  end
end
