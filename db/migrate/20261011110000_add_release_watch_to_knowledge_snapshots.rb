# frozen_string_literal: true

# The snapshot and change-queue tables were built in April for a "scan, diff,
# human review" loop that was never wired up. The release watcher (backlog
# E75) uses them: a snapshot per frontend build, a queue item per new, changed
# or removed place in the product, and AI-drafted help on each item waiting
# for review.
class AddReleaseWatchToKnowledgeSnapshots < ActiveRecord::Migration[8.0]
  def change
    change_table :knowledge_snapshots, bulk: true do |t|
      t.string :source
      t.string :commit_sha
      t.jsonb  :atlas,   null: false, default: {}
      t.jsonb  :commits, null: false, default: []
      t.index  %i[source snapshot_at]
    end

    change_table :knowledge_change_queue, bulk: true do |t|
      t.jsonb    :context, null: false, default: {}
      t.jsonb    :drafts,  null: false, default: {}
      t.string   :draft_status, null: false, default: 'pending'
      t.text     :draft_error
      t.datetime :published_at
      t.bigint   :published_article_id
      t.bigint   :published_note_id
      t.bigint   :published_tour_id
    end
  end
end
