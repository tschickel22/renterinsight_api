# frozen_string_literal: true

# E68 step 4: ask several contractors to bid on a phase (or a whole project),
# take their bids in the portal or by phone, and award one.
class CreateProjectBids < ActiveRecord::Migration[8.0]
  def change
    create_table :project_bid_requests do |t|
      t.references :company, null: false, index: true
      t.references :project, null: false, index: true
      # Blank means the whole project.
      t.references :project_phase, index: true
      t.string :title, null: false
      t.text :scope
      t.date :bids_due_on
      t.date :start_wanted_on
      t.string :status, null: false, default: 'open'
      t.bigint :awarded_bid_id
      t.bigint :awarded_by_id
      t.datetime :awarded_at
      # The phase or project contractor before the award, so Undo can put it back.
      t.bigint :previous_vendor_id
      t.datetime :cancelled_at
      t.bigint :created_by_id
      t.timestamps
    end
    add_index :project_bid_requests, %i[company_id status]

    create_table :project_bids do |t|
      t.references :company, null: false, index: true
      t.references :project_bid_request, null: false, index: true
      t.references :vendor, null: false, index: true
      t.string :status, null: false, default: 'invited'
      t.decimal :amount, precision: 12, scale: 2
      t.date :can_start_on
      t.integer :duration_days
      t.text :notes
      t.datetime :invited_at
      t.datetime :submitted_at
      # Staff who typed the bid in for the contractor (a phone bid).
      t.bigint :entered_by_id
      # The committed cost line the award made.
      t.bigint :project_cost_item_id
      t.timestamps
    end
    add_index :project_bids, %i[project_bid_request_id vendor_id], unique: true
  end
end
