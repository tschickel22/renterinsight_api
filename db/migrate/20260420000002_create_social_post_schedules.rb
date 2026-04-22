# frozen_string_literal: true

class CreateSocialPostSchedules < ActiveRecord::Migration[8.0]
  def change
    create_table :social_post_schedules do |t|
      t.bigint :company_id,  null: false
      t.bigint :location_id

      t.string :name, default: 'Default Schedule'
      t.string :frequency, null: false

      t.jsonb  :preferred_times, default: ['10:00']
      t.jsonb  :preferred_days,  default: [1, 3, 5]

      t.boolean :auto_approve,    default: false
      t.boolean :require_vehicle, default: true

      t.jsonb  :intent_rotation, default: %w[new_arrival specific_unit education social_proof lifestyle]

      t.string :platform,  default: 'facebook'
      t.string :post_type, default: 'company_page'
      t.string :tone,      default: 'friendly'

      t.bigint :intake_form_id
      t.bigint :notify_user_id

      t.boolean  :active,      default: true
      t.datetime :last_generated_at
      t.datetime :next_scheduled_at
      t.string   :last_intent_used

      t.boolean  :is_deleted, default: false

      t.timestamps
    end

    add_index :social_post_schedules, [:company_id, :active]
  end
end
