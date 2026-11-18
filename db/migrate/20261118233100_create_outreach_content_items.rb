# frozen_string_literal: true

# Videos and links Proactive Outreach may send (backlog E105). New table only,
# so it is safe while old and new code run side by side during a release.
class CreateOutreachContentItems < ActiveRecord::Migration[8.0]
  def change
    create_table :outreach_content_items do |t|
      t.bigint :company_id, null: false
      t.string :title, null: false
      t.string :url, null: false
      t.string :topic
      t.string :use_when
      t.text :description
      t.string :source_kind, null: false, default: 'manual'
      t.bigint :source_campaign_id
      t.bigint :source_step_id
      t.string :status, null: false, default: 'pending'
      t.bigint :approved_by_user_id
      t.datetime :approved_at
      t.timestamps
    end
    add_index :outreach_content_items, %i[company_id url], unique: true
    add_index :outreach_content_items, %i[company_id status]
    add_foreign_key :outreach_content_items, :companies
  end
end
