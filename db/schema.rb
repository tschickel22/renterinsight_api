# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_10_03_114822) do
  create_table "accounts", force: :cascade do |t|
    t.integer "company_id"
    t.string "name", null: false
    t.string "status", default: "active", null: false
    t.string "email"
    t.string "phone"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_accounts_on_company_id"
    t.index ["name"], name: "index_accounts_on_name"
  end

  create_table "activities", force: :cascade do |t|
    t.integer "lead_id", null: false
    t.integer "user_id"
    t.string "activity_type", null: false
    t.text "description", null: false
    t.string "outcome"
    t.integer "duration"
    t.datetime "scheduled_date"
    t.datetime "completed_date"
    t.json "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["activity_type"], name: "index_activities_on_activity_type"
    t.index ["lead_id", "created_at"], name: "index_activities_on_lead_id_and_created_at"
    t.index ["lead_id"], name: "index_activities_on_lead_id"
    t.index ["user_id"], name: "index_activities_on_user_id"
  end

  create_table "ai_insights", force: :cascade do |t|
    t.integer "lead_id", null: false
    t.string "insight_type", null: false
    t.string "title", null: false
    t.text "description", null: false
    t.integer "confidence", default: 0
    t.boolean "actionable", default: false
    t.json "suggested_actions", default: []
    t.json "metadata", default: {}
    t.datetime "generated_at", null: false
    t.boolean "is_read", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["generated_at"], name: "index_ai_insights_on_generated_at"
    t.index ["insight_type"], name: "index_ai_insights_on_insight_type"
    t.index ["lead_id", "is_read"], name: "index_ai_insights_on_lead_id_and_is_read"
    t.index ["lead_id"], name: "index_ai_insights_on_lead_id"
  end

  create_table "communication_logs", force: :cascade do |t|
    t.integer "lead_id", null: false
    t.string "comm_type", null: false
    t.string "direction", null: false
    t.string "subject"
    t.text "content", null: false
    t.string "status", null: false
    t.datetime "sent_at"
    t.datetime "delivered_at"
    t.datetime "opened_at"
    t.datetime "clicked_at"
    t.json "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["comm_type"], name: "index_communication_logs_on_comm_type"
    t.index ["lead_id", "sent_at"], name: "index_communication_logs_on_lead_id_and_sent_at"
    t.index ["lead_id"], name: "index_communication_logs_on_lead_id"
    t.index ["status"], name: "index_communication_logs_on_status"
  end

  create_table "companies", force: :cascade do |t|
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "deals", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "lead_id"
    t.string "title", default: "Untitled Deal", null: false
    t.string "stage", default: "new", null: false
    t.integer "amount_cents", default: 0, null: false
    t.date "expected_close_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "stage"], name: "index_deals_on_account_id_and_stage"
    t.index ["account_id"], name: "index_deals_on_account_id"
    t.index ["expected_close_on"], name: "index_deals_on_expected_close_on"
    t.index ["lead_id"], name: "index_deals_on_lead_id"
  end

  create_table "intake_forms", force: :cascade do |t|
    t.string "name"
    t.text "description"
    t.json "schema"
    t.boolean "is_active"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "intake_submissions", force: :cascade do |t|
    t.integer "intake_form_id"
    t.json "data"
    t.string "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "lead_scores", force: :cascade do |t|
    t.integer "lead_id", null: false
    t.integer "score", default: 0, null: false
    t.string "reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["lead_id", "score"], name: "index_lead_scores_on_lead_id_and_score"
    t.index ["lead_id"], name: "index_lead_scores_on_lead_id"
  end

  create_table "lead_tasks", force: :cascade do |t|
    t.integer "lead_id", null: false
    t.string "title"
    t.datetime "due_at"
    t.boolean "done"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["lead_id"], name: "index_lead_tasks_on_lead_id"
  end

  create_table "leads", force: :cascade do |t|
    t.string "first_name"
    t.string "last_name"
    t.string "email"
    t.string "phone"
    t.text "notes"
    t.integer "source_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "status"
    t.integer "converted_account_id"
    t.index ["converted_account_id"], name: "index_leads_on_converted_account_id"
    t.index ["source_id"], name: "index_leads_on_source_id"
  end

  create_table "nurture_enrollments", force: :cascade do |t|
    t.integer "lead_id", null: false
    t.integer "nurture_sequence_id", null: false
    t.string "status", default: "idle", null: false
    t.integer "current_step_index"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["lead_id", "nurture_sequence_id"], name: "idx_unique_active_enrollment", unique: true, where: "status IN ('running','paused')"
    t.index ["lead_id", "nurture_sequence_id"], name: "index_nurture_enrollments_on_lead_id_and_nurture_sequence_id"
    t.index ["lead_id"], name: "index_nurture_enrollments_on_lead_id"
    t.index ["nurture_sequence_id"], name: "index_nurture_enrollments_on_nurture_sequence_id"
  end

  create_table "nurture_sequences", force: :cascade do |t|
    t.string "name", null: false
    t.boolean "is_active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
  end

  create_table "nurture_steps", force: :cascade do |t|
    t.integer "nurture_sequence_id", null: false
    t.string "step_type", null: false
    t.string "subject"
    t.text "body"
    t.integer "wait_days"
    t.integer "position", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "template_id"
    t.index ["nurture_sequence_id", "position"], name: "index_nurture_steps_on_nurture_sequence_id_and_position"
    t.index ["nurture_sequence_id"], name: "index_nurture_steps_on_nurture_sequence_id"
    t.index ["template_id"], name: "index_nurture_steps_on_template_id"
  end

  create_table "reminders", force: :cascade do |t|
    t.integer "lead_id", null: false
    t.integer "user_id", null: false
    t.string "reminder_type", null: false
    t.string "title", null: false
    t.text "description"
    t.datetime "due_date", null: false
    t.boolean "is_completed", default: false
    t.string "priority", default: "medium"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["lead_id", "is_completed"], name: "index_reminders_on_lead_id_and_is_completed"
    t.index ["lead_id"], name: "index_reminders_on_lead_id"
    t.index ["priority"], name: "index_reminders_on_priority"
    t.index ["user_id", "due_date"], name: "index_reminders_on_user_id_and_due_date"
    t.index ["user_id"], name: "index_reminders_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.string "scope_type"
    t.bigint "scope_id"
    t.string "key", null: false
    t.text "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["scope_type", "scope_id", "key"], name: "idx_settings_scope_key", unique: true
    t.index ["scope_type", "scope_id"], name: "index_settings_on_scope_type_and_scope_id"
  end

  create_table "sources", force: :cascade do |t|
    t.string "name"
    t.string "source_type"
    t.string "tracking_code"
    t.boolean "is_active"
    t.decimal "conversion_rate"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "tag_assignments", force: :cascade do |t|
    t.integer "tag_id", null: false
    t.string "entity_type", null: false
    t.string "entity_id", null: false
    t.string "assigned_by"
    t.datetime "assigned_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_type", "entity_id"], name: "index_tag_assignments_on_entity_type_and_entity_id"
    t.index ["tag_id", "entity_type", "entity_id"], name: "idx_tag_assignments_unique", unique: true
    t.index ["tag_id"], name: "index_tag_assignments_on_tag_id"
  end

  create_table "tags", force: :cascade do |t|
    t.string "name", null: false
    t.string "description"
    t.string "color", default: "#6B7280", null: false
    t.string "category"
    t.json "tag_type", default: []
    t.boolean "is_system", default: false
    t.boolean "is_active", default: true
    t.integer "usage_count", default: 0
    t.string "created_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_tags_on_category"
    t.index ["name"], name: "index_tags_on_name", unique: true
  end

  create_table "templates", force: :cascade do |t|
    t.string "name", null: false
    t.string "template_type", null: false
    t.string "subject"
    t.text "body"
    t.boolean "is_active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["template_type", "name"], name: "index_templates_on_template_type_and_name"
  end

  create_table "users", force: :cascade do |t|
    t.string "email"
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "accounts", "companies"
  add_foreign_key "activities", "leads"
  add_foreign_key "activities", "users"
  add_foreign_key "ai_insights", "leads"
  add_foreign_key "communication_logs", "leads"
  add_foreign_key "deals", "accounts"
  add_foreign_key "deals", "leads"
  add_foreign_key "lead_scores", "leads"
  add_foreign_key "lead_tasks", "leads"
  add_foreign_key "leads", "accounts", column: "converted_account_id"
  add_foreign_key "leads", "sources"
  add_foreign_key "nurture_enrollments", "leads"
  add_foreign_key "nurture_enrollments", "nurture_sequences"
  add_foreign_key "nurture_steps", "nurture_sequences"
  add_foreign_key "nurture_steps", "templates"
  add_foreign_key "reminders", "leads"
  add_foreign_key "reminders", "users"
  add_foreign_key "tag_assignments", "tags"
end
