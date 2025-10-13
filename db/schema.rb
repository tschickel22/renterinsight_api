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

ActiveRecord::Schema[8.0].define(version: 2025_10_13_200003) do
  create_table "account_activities", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "user_id"
    t.string "activity_type", null: false
    t.text "description", null: false
    t.string "outcome"
    t.integer "duration"
    t.datetime "scheduled_date"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "assigned_to_id"
    t.bigint "related_activity_id"
    t.string "subject"
    t.string "status"
    t.string "priority"
    t.datetime "due_date"
    t.datetime "start_time"
    t.datetime "end_time"
    t.integer "duration_minutes"
    t.datetime "completed_at"
    t.string "call_direction"
    t.string "call_outcome"
    t.string "phone_number"
    t.string "meeting_location"
    t.string "meeting_link"
    t.text "meeting_attendees"
    t.text "reminder_method"
    t.datetime "reminder_time"
    t.boolean "reminder_sent", default: false
    t.float "estimated_hours"
    t.float "actual_hours"
    t.text "outcome_notes"
    t.json "metadata"
    t.index ["account_id"], name: "index_account_activities_on_account_id"
    t.index ["activity_type"], name: "index_account_activities_on_activity_type"
    t.index ["assigned_to_id"], name: "index_account_activities_on_assigned_to_id"
    t.index ["completed_at"], name: "index_account_activities_on_completed_at"
    t.index ["created_at"], name: "index_account_activities_on_created_at"
    t.index ["due_date"], name: "index_account_activities_on_due_date"
    t.index ["outcome"], name: "index_account_activities_on_outcome"
    t.index ["priority"], name: "index_account_activities_on_priority"
    t.index ["related_activity_id"], name: "index_account_activities_on_related_activity_id"
    t.index ["status"], name: "index_account_activities_on_status"
    t.index ["user_id"], name: "index_account_activities_on_user_id"
  end

  create_table "accounts", force: :cascade do |t|
    t.integer "company_id"
    t.string "name", null: false
    t.string "status", default: "active", null: false
    t.string "email"
    t.string "phone"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "account_type"
    t.string "website"
    t.string "industry"
    t.string "rating"
    t.string "ownership"
    t.decimal "annual_revenue", precision: 15, scale: 2
    t.integer "employee_count"
    t.text "description"
    t.text "notes"
    t.string "billing_street"
    t.string "billing_city"
    t.string "billing_state"
    t.string "billing_postal_code"
    t.string "billing_country"
    t.string "shipping_street"
    t.string "shipping_city"
    t.string "shipping_state"
    t.string "shipping_postal_code"
    t.string "shipping_country"
    t.bigint "parent_account_id"
    t.bigint "source_id"
    t.bigint "owner_id"
    t.string "account_number"
    t.datetime "converted_date"
    t.datetime "last_activity_date"
    t.boolean "is_deleted", default: false, null: false
    t.datetime "deleted_at"
    t.index ["account_number"], name: "index_accounts_on_account_number", unique: true
    t.index ["account_type"], name: "index_accounts_on_account_type"
    t.index ["company_id"], name: "index_accounts_on_company_id"
    t.index ["is_deleted"], name: "index_accounts_on_is_deleted"
    t.index ["name"], name: "index_accounts_on_name"
    t.index ["owner_id"], name: "index_accounts_on_owner_id"
    t.index ["parent_account_id"], name: "index_accounts_on_parent_account_id"
    t.index ["rating"], name: "index_accounts_on_rating"
    t.index ["source_id"], name: "index_accounts_on_source_id"
    t.index ["status"], name: "index_accounts_on_status"
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.integer "record_id", null: false
    t.integer "blob_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.integer "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
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

  create_table "communication_events", force: :cascade do |t|
    t.integer "communication_id", null: false
    t.string "event_type", null: false
    t.datetime "occurred_at", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.text "details"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["communication_id", "event_type"], name: "idx_events_on_communication_and_type"
    t.index ["communication_id"], name: "index_communication_events_on_communication_id"
    t.index ["event_type"], name: "index_communication_events_on_event_type"
    t.index ["occurred_at"], name: "index_communication_events_on_occurred_at"
  end

  create_table "communication_preferences", force: :cascade do |t|
    t.string "recipient_type", null: false
    t.integer "recipient_id", null: false
    t.string "channel", null: false
    t.string "category"
    t.boolean "opted_in", default: true, null: false
    t.datetime "opted_in_at"
    t.datetime "opted_out_at"
    t.string "unsubscribe_token"
    t.text "opted_out_reason"
    t.string "ip_address"
    t.string "user_agent"
    t.text "compliance_metadata"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_communication_preferences_on_category"
    t.index ["channel"], name: "index_communication_preferences_on_channel"
    t.index ["opted_in"], name: "index_communication_preferences_on_opted_in"
    t.index ["recipient_type", "recipient_id", "channel", "category"], name: "idx_prefs_on_recipient_channel_category", unique: true
    t.index ["recipient_type", "recipient_id"], name: "index_communication_preferences_on_recipient"
    t.index ["unsubscribe_token"], name: "index_communication_preferences_on_unsubscribe_token", unique: true
  end

  create_table "communication_templates", force: :cascade do |t|
    t.string "name", null: false
    t.string "channel", null: false
    t.text "subject_template"
    t.text "body_template", null: false
    t.string "category"
    t.json "variables", default: "{}"
    t.boolean "active", default: true
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_communication_templates_on_active"
    t.index ["category"], name: "index_communication_templates_on_category"
    t.index ["channel"], name: "index_communication_templates_on_channel"
    t.index ["name"], name: "index_communication_templates_on_name"
  end

  create_table "communication_threads", force: :cascade do |t|
    t.string "subject"
    t.string "channel"
    t.string "status", default: "active", null: false
    t.datetime "last_message_at"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "participant_type"
    t.bigint "participant_id"
    t.index ["channel"], name: "index_communication_threads_on_channel"
    t.index ["last_message_at"], name: "index_communication_threads_on_last_message_at"
    t.index ["participant_type", "participant_id"], name: "index_comm_threads_on_participant"
    t.index ["status"], name: "index_communication_threads_on_status"
  end

  create_table "communications", force: :cascade do |t|
    t.string "communicable_type", null: false
    t.integer "communicable_id", null: false
    t.integer "communication_thread_id"
    t.string "direction", null: false
    t.string "channel", null: false
    t.string "provider"
    t.string "status", default: "pending", null: false
    t.string "subject"
    t.text "body"
    t.string "from_address"
    t.string "to_address"
    t.text "cc_addresses"
    t.text "bcc_addresses"
    t.string "reply_to"
    t.boolean "portal_visible", default: false
    t.datetime "sent_at"
    t.datetime "delivered_at"
    t.datetime "failed_at"
    t.text "error_message"
    t.text "metadata"
    t.string "external_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "template_id"
    t.datetime "scheduled_for"
    t.string "scheduled_status", default: "immediate"
    t.string "scheduled_job_id"
    t.index ["channel"], name: "index_communications_on_channel"
    t.index ["communicable_type", "communicable_id"], name: "index_communications_on_communicable"
    t.index ["communication_thread_id"], name: "index_communications_on_communication_thread_id"
    t.index ["created_at"], name: "index_communications_on_created_at"
    t.index ["direction"], name: "index_communications_on_direction"
    t.index ["external_id"], name: "index_communications_on_external_id"
    t.index ["portal_visible"], name: "index_communications_on_portal_visible"
    t.index ["scheduled_for"], name: "index_communications_on_scheduled_for"
    t.index ["scheduled_status", "scheduled_for"], name: "index_communications_on_scheduled_status_and_scheduled_for"
    t.index ["scheduled_status"], name: "index_communications_on_scheduled_status"
    t.index ["status"], name: "index_communications_on_status"
    t.index ["template_id"], name: "index_communications_on_template_id"
  end

  create_table "companies", force: :cascade do |t|
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "contacts", force: :cascade do |t|
    t.integer "account_id"
    t.integer "company_id"
    t.string "first_name", null: false
    t.string "last_name"
    t.string "email"
    t.string "phone"
    t.string "title"
    t.string "department"
    t.boolean "is_primary", default: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_contacts_on_account_id"
    t.index ["company_id"], name: "index_contacts_on_company_id"
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
    t.string "public_id"
    t.bigint "company_id"
    t.text "thank_you_message"
    t.string "redirect_url"
    t.string "submit_button_text", default: "Submit"
    t.integer "submission_count", default: 0
    t.bigint "source_id"
    t.index ["company_id"], name: "index_intake_forms_on_company_id"
    t.index ["public_id"], name: "index_intake_forms_on_public_id", unique: true
    t.index ["source_id"], name: "index_intake_forms_on_source_id"
  end

  create_table "intake_submissions", force: :cascade do |t|
    t.integer "intake_form_id"
    t.json "data"
    t.string "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "ip_address"
    t.text "user_agent"
    t.string "referrer"
    t.datetime "submitted_at"
    t.boolean "lead_created", default: false
    t.bigint "lead_id"
    t.index ["submitted_at"], name: "index_intake_submissions_on_submitted_at"
  end

  create_table "lead_activities", force: :cascade do |t|
    t.integer "lead_id", null: false
    t.integer "user_id", null: false
    t.integer "assigned_to_id"
    t.string "activity_type", null: false
    t.string "subject", null: false
    t.text "description"
    t.string "status", default: "pending"
    t.string "priority", default: "medium"
    t.datetime "due_date"
    t.datetime "start_time"
    t.datetime "end_time"
    t.integer "duration_minutes"
    t.datetime "completed_at"
    t.string "call_direction"
    t.string "call_outcome"
    t.string "phone_number"
    t.string "meeting_location"
    t.string "meeting_link"
    t.text "meeting_attendees"
    t.text "reminder_method"
    t.datetime "reminder_time"
    t.boolean "reminder_sent", default: false
    t.integer "estimated_hours"
    t.integer "actual_hours"
    t.integer "related_activity_id"
    t.json "metadata", default: {}
    t.text "outcome_notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["assigned_to_id", "status"], name: "index_lead_activities_on_assigned_to_id_and_status"
    t.index ["assigned_to_id"], name: "index_lead_activities_on_assigned_to_id"
    t.index ["due_date"], name: "index_lead_activities_on_due_date"
    t.index ["lead_id", "activity_type"], name: "index_lead_activities_on_lead_id_and_activity_type"
    t.index ["lead_id"], name: "index_lead_activities_on_lead_id"
    t.index ["related_activity_id"], name: "index_lead_activities_on_related_activity_id"
    t.index ["start_time"], name: "index_lead_activities_on_start_time"
    t.index ["user_id"], name: "index_lead_activities_on_user_id"
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
    t.bigint "company_id"
    t.boolean "is_converted", default: false
    t.datetime "converted_at"
    t.index ["company_id"], name: "index_leads_on_company_id"
    t.index ["converted_account_id"], name: "index_leads_on_converted_account_id"
    t.index ["source_id"], name: "index_leads_on_source_id"
  end

  create_table "notes", force: :cascade do |t|
    t.text "content", null: false
    t.string "entity_type", null: false
    t.string "entity_id", null: false
    t.integer "user_id"
    t.string "created_by_name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_notes_on_created_at"
    t.index ["entity_type", "entity_id"], name: "index_notes_on_entity_type_and_entity_id"
    t.index ["user_id"], name: "index_notes_on_user_id"
  end

  create_table "nurture_enrollments", force: :cascade do |t|
    t.integer "lead_id"
    t.integer "nurture_sequence_id", null: false
    t.string "status", default: "idle", null: false
    t.integer "current_step_index"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "enrollable_type"
    t.integer "enrollable_id"
    t.index ["enrollable_type", "enrollable_id"], name: "index_nurture_enrollments_on_enrollable_type_and_enrollable_id"
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

  create_table "quotes", force: :cascade do |t|
    t.integer "account_id"
    t.integer "contact_id"
    t.string "customer_id"
    t.string "vehicle_id"
    t.string "quote_number", null: false
    t.string "status", default: "draft", null: false
    t.decimal "subtotal", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "tax", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "total", precision: 15, scale: 2, default: "0.0", null: false
    t.json "items", default: []
    t.date "valid_until"
    t.datetime "sent_at"
    t.datetime "viewed_at"
    t.datetime "accepted_at"
    t.datetime "rejected_at"
    t.text "notes"
    t.json "custom_fields", default: {}
    t.boolean "is_deleted", default: false, null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_quotes_on_account_id"
    t.index ["contact_id"], name: "index_quotes_on_contact_id"
    t.index ["created_at"], name: "index_quotes_on_created_at"
    t.index ["customer_id"], name: "index_quotes_on_customer_id"
    t.index ["is_deleted"], name: "index_quotes_on_is_deleted"
    t.index ["quote_number"], name: "index_quotes_on_quote_number", unique: true
    t.index ["status"], name: "index_quotes_on_status"
    t.index ["valid_until"], name: "index_quotes_on_valid_until"
    t.index ["vehicle_id"], name: "index_quotes_on_vehicle_id"
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
    t.datetime "completed_at"
    t.index ["due_date"], name: "index_reminders_on_due_date"
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

  add_foreign_key "account_activities", "account_activities", column: "related_activity_id"
  add_foreign_key "account_activities", "accounts"
  add_foreign_key "account_activities", "users"
  add_foreign_key "account_activities", "users", column: "assigned_to_id"
  add_foreign_key "accounts", "accounts", column: "parent_account_id"
  add_foreign_key "accounts", "companies"
  add_foreign_key "accounts", "sources"
  add_foreign_key "accounts", "users", column: "owner_id"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "activities", "leads"
  add_foreign_key "activities", "users"
  add_foreign_key "ai_insights", "leads"
  add_foreign_key "communication_events", "communications"
  add_foreign_key "communications", "communication_templates", column: "template_id"
  add_foreign_key "communications", "communication_threads"
  add_foreign_key "deals", "accounts"
  add_foreign_key "deals", "leads"
  add_foreign_key "intake_forms", "companies"
  add_foreign_key "intake_forms", "sources"
  add_foreign_key "intake_submissions", "leads"
  add_foreign_key "lead_activities", "lead_activities", column: "related_activity_id"
  add_foreign_key "lead_activities", "leads"
  add_foreign_key "lead_activities", "users"
  add_foreign_key "lead_activities", "users", column: "assigned_to_id"
  add_foreign_key "lead_scores", "leads"
  add_foreign_key "lead_tasks", "leads"
  add_foreign_key "leads", "accounts", column: "converted_account_id"
  add_foreign_key "leads", "companies"
  add_foreign_key "leads", "sources"
  add_foreign_key "notes", "users"
  add_foreign_key "nurture_enrollments", "leads"
  add_foreign_key "nurture_enrollments", "nurture_sequences"
  add_foreign_key "nurture_steps", "nurture_sequences"
  add_foreign_key "nurture_steps", "templates"
  add_foreign_key "quotes", "accounts"
  add_foreign_key "quotes", "contacts"
  add_foreign_key "reminders", "leads"
  add_foreign_key "reminders", "users"
  add_foreign_key "tag_assignments", "tags"
end
