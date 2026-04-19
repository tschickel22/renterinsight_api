# frozen_string_literal: true

class AddUtmFieldsToLeads < ActiveRecord::Migration[8.0]
  def change
    change_table :leads, bulk: true do |t|
      t.string :utm_source
      t.string :utm_medium
      t.string :utm_campaign
      t.string :utm_content
      t.string :utm_term

      t.bigint :social_post_id
      t.string :social_intent

      t.jsonb :survey_answers

      t.integer  :health_score, default: 0
      t.datetime :health_score_updated_at
      t.datetime :last_activity_scored_at
    end

    add_index :leads, :utm_source
    add_index :leads, :utm_medium
    add_index :leads, :utm_campaign
    add_index :leads, :social_post_id
    add_index :leads, :health_score
  end
end
