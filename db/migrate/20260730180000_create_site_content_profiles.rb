# frozen_string_literal: true

class CreateSiteContentProfiles < ActiveRecord::Migration[8.0]
  def change
    create_table :site_content_profiles do |t|
      t.references :company, null: false, foreign_key: true
      t.references :location, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }

      t.string :source_url, null: false
      t.string :display_name
      t.string :status, null: false, default: 'pending'

      t.jsonb :profile, null: false, default: {}
      t.jsonb :report, null: false, default: {}
      t.integer :schema_version, null: false, default: 1

      t.string :model_version
      t.integer :input_tokens
      t.integer :output_tokens
      t.text :error_message
      t.boolean :robots_allowed, default: true

      # The share link lives on the PROFILE, not on a website — a prospect demo
      # must be emailable without creating a Website record for every pitch.
      t.string :preview_token
      t.datetime :preview_expires_at
      t.string :preview_template_ids, array: true, default: []

      t.timestamps
    end

    add_index :site_content_profiles, :preview_token, unique: true
    add_index :site_content_profiles, %i[company_id status]

    create_table :site_profile_projections do |t|
      t.references :site_content_profile, null: false, foreign_key: true, index: { name: 'idx_projections_on_profile' }
      t.references :website, foreign_key: true
      t.references :parent, foreign_key: { to_table: :site_profile_projections }

      t.string :template_id, null: false
      t.jsonb :projected_template, null: false, default: {}
      t.jsonb :report, null: false, default: {}
      t.boolean :polished, null: false, default: false

      t.string :model_version
      t.integer :input_tokens
      t.integer :output_tokens

      t.timestamps
    end

    add_index :site_profile_projections, %i[site_content_profile_id template_id],
              name: 'idx_projections_on_profile_and_template'
  end
end
