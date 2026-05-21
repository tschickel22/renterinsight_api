class AddAttachmentsToNurtureStepsAndTrackedLinks < ActiveRecord::Migration[8.0]
  def change
    add_column :nurture_steps, :attachments, :jsonb, default: []

    create_table :tracked_links do |t|
      t.references :company, null: false, foreign_key: true
      t.references :communication, null: true, foreign_key: true
      t.string :token, null: false
      t.string :s3_key, null: false
      t.string :filename
      t.string :content_type
      t.integer :file_size
      t.string :entity_type
      t.bigint :entity_id
      t.string :source_type
      t.bigint :source_id
      t.integer :click_count, default: 0
      t.datetime :first_clicked_at
      t.datetime :last_clicked_at
      t.timestamps

      t.index :token, unique: true
      t.index [:entity_type, :entity_id]
      t.index [:source_type, :source_id]
    end

    create_table :tracked_link_events do |t|
      t.references :tracked_link, null: false, foreign_key: true
      t.string :ip_address
      t.string :user_agent
      t.datetime :clicked_at, null: false
      t.timestamps

      t.index :clicked_at
    end
  end
end
