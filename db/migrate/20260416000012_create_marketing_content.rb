# frozen_string_literal: true

class CreateMarketingContent < ActiveRecord::Migration[8.0]
  # content_type values: blog_post, social_post, email, video_script, landing_page, release_note
  # status values:       draft, ready, published, archived
  def change
    create_table :marketing_content do |t|
      t.references :knowledge_module,  null: true, foreign_key: true, index: true
      t.references :knowledge_feature, null: true, foreign_key: true, index: true
      t.string   :content_type, null: false
      t.string   :title,        null: false
      t.text     :content
      t.string   :status,       null: false, default: 'draft'
      t.datetime :published_at
      t.timestamps
    end

    add_index :marketing_content, :content_type
    add_index :marketing_content, :status
    add_index :marketing_content, :published_at
  end
end
