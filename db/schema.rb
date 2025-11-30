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

ActiveRecord::Schema[8.0].define(version: 2025_11_28_225559) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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
    t.bigint "location_id"
    t.index ["account_number"], name: "index_accounts_on_account_number", unique: true
    t.index ["account_type"], name: "index_accounts_on_account_type"
    t.index ["company_id", "location_id"], name: "index_accounts_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_accounts_on_company_id"
    t.index ["is_deleted"], name: "index_accounts_on_is_deleted"
    t.index ["location_id"], name: "index_accounts_on_location_id"
    t.index ["name"], name: "index_accounts_on_name"
    t.index ["owner_id"], name: "index_accounts_on_owner_id"
    t.index ["parent_account_id"], name: "index_accounts_on_parent_account_id"
    t.index ["rating"], name: "index_accounts_on_rating"
    t.index ["source_id"], name: "index_accounts_on_source_id"
    t.index ["status"], name: "index_accounts_on_status"
  end

  create_table "actions", force: :cascade do |t|
    t.string "key", limit: 100, null: false
    t.string "name", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_actions_on_key", unique: true
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

  create_table "api_logs", force: :cascade do |t|
    t.bigint "company_id"
    t.string "provider", null: false
    t.string "action"
    t.string "url"
    t.string "status", default: "pending"
    t.text "request"
    t.text "response"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.integer "duration_ms"
    t.string "ip_address"
    t.string "user_agent"
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "provider", "created_at"], name: "index_api_logs_on_company_id_and_provider_and_created_at"
    t.index ["company_id"], name: "index_api_logs_on_company_id"
    t.index ["created_at"], name: "index_api_logs_on_created_at"
    t.index ["provider", "action"], name: "index_api_logs_on_provider_and_action"
    t.index ["provider"], name: "index_api_logs_on_provider"
    t.index ["status"], name: "index_api_logs_on_status"
  end

  create_table "approval_actions", force: :cascade do |t|
    t.integer "approval_step_id", null: false
    t.integer "user_id", null: false
    t.string "action_type", null: false
    t.text "notes"
    t.datetime "actioned_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["action_type"], name: "index_approval_actions_on_action_type"
    t.index ["approval_step_id", "actioned_at"], name: "index_approval_actions_on_approval_step_id_and_actioned_at"
    t.index ["approval_step_id"], name: "index_approval_actions_on_approval_step_id"
    t.index ["user_id"], name: "index_approval_actions_on_user_id"
  end

  create_table "approval_steps", force: :cascade do |t|
    t.integer "approval_workflow_id", null: false
    t.integer "step_order", null: false
    t.integer "approver_user_id"
    t.string "status", default: "pending", null: false
    t.string "required_action"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["approval_workflow_id", "step_order"], name: "index_approval_steps_on_approval_workflow_id_and_step_order"
    t.index ["approval_workflow_id"], name: "index_approval_steps_on_approval_workflow_id"
    t.index ["approver_user_id"], name: "index_approval_steps_on_approver_user_id"
    t.index ["status"], name: "index_approval_steps_on_status"
  end

  create_table "approval_workflows", force: :cascade do |t|
    t.integer "deal_id", null: false
    t.string "workflow_type", null: false
    t.string "status", default: "pending", null: false
    t.decimal "required_amount", precision: 12, scale: 2
    t.text "reason"
    t.text "notes"
    t.integer "requested_by_id"
    t.integer "approved_by_id"
    t.datetime "approved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_id"], name: "index_approval_workflows_on_approved_by_id"
    t.index ["deal_id", "status"], name: "index_approval_workflows_on_deal_id_and_status"
    t.index ["deal_id"], name: "index_approval_workflows_on_deal_id"
    t.index ["requested_by_id"], name: "index_approval_workflows_on_requested_by_id"
    t.index ["status"], name: "index_approval_workflows_on_status"
    t.index ["workflow_type"], name: "index_approval_workflows_on_workflow_type"
  end

  create_table "bank_accounts", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id", null: false
    t.string "account_purpose", null: false
    t.string "account_type", null: false
    t.string "bank_name"
    t.string "routing_number", null: false
    t.string "account_number", null: false
    t.string "account_holder_name"
    t.string "external_id"
    t.boolean "is_active", default: true, null: false
    t.boolean "is_verified", default: false, null: false
    t.datetime "verified_at"
    t.boolean "is_deleted", default: false
    t.datetime "deleted_at"
    t.string "created_by"
    t.string "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "display_last_four", limit: 4
    t.text "admin_notes"
    t.datetime "locked_at"
    t.index ["company_id", "location_id"], name: "index_bank_accounts_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_bank_accounts_on_company_id"
    t.index ["external_id"], name: "index_bank_accounts_on_external_id"
    t.index ["is_deleted"], name: "index_bank_accounts_on_is_deleted"
    t.index ["location_id", "account_purpose"], name: "index_bank_accounts_on_location_id_and_account_purpose"
    t.index ["location_id"], name: "index_bank_accounts_on_location_id"
  end

  create_table "brochure_templates", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.string "template_key", null: false
    t.string "theme"
    t.string "preview_image"
    t.jsonb "template_data", default: {}, null: false
    t.boolean "is_default", default: false
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_brochure_templates_on_active"
    t.index ["is_default"], name: "index_brochure_templates_on_is_default"
    t.index ["template_key"], name: "index_brochure_templates_on_template_key", unique: true
  end

  create_table "brochures", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "title", null: false
    t.text "description"
    t.string "public_id", null: false
    t.string "template_name"
    t.jsonb "template_data", default: {}
    t.jsonb "vehicle_ids", default: []
    t.boolean "is_public", default: true
    t.integer "view_count", default: 0
    t.integer "share_count", default: 0
    t.integer "download_count", default: 0
    t.string "status", default: "active"
    t.boolean "is_deleted", default: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "location_id"
    t.index ["company_id", "is_deleted"], name: "index_brochures_on_company_id_and_is_deleted"
    t.index ["company_id", "location_id"], name: "index_brochures_on_company_id_and_location_id"
    t.index ["company_id", "status"], name: "index_brochures_on_company_id_and_status"
    t.index ["company_id"], name: "index_brochures_on_company_id"
    t.index ["created_at"], name: "index_brochures_on_created_at"
    t.index ["location_id"], name: "index_brochures_on_location_id"
    t.index ["public_id"], name: "index_brochures_on_public_id", unique: true
  end

  create_table "buyer_portal_accesses", force: :cascade do |t|
    t.string "buyer_type", null: false
    t.integer "buyer_id", null: false
    t.string "email", null: false
    t.string "password_digest"
    t.string "reset_token"
    t.datetime "reset_token_expires_at"
    t.string "login_token"
    t.datetime "login_token_expires_at"
    t.datetime "last_login_at"
    t.integer "login_count", default: 0
    t.string "last_login_ip"
    t.boolean "portal_enabled", default: true
    t.boolean "email_opt_in", default: true
    t.boolean "sms_opt_in", default: true
    t.boolean "marketing_opt_in", default: false
    t.text "preference_history"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "company_id"
    t.string "role", default: "Client"
    t.string "status", default: "Pending"
    t.json "permissions", default: []
    t.datetime "invitation_sent_at"
    t.string "invitation_token"
    t.datetime "invitation_token_expires_at"
    t.datetime "invitation_accepted_at"
    t.index ["buyer_type", "buyer_id", "company_id"], name: "index_buyer_portal_on_buyer_and_company"
    t.index ["buyer_type", "buyer_id"], name: "index_buyer_portal_accesses_on_buyer"
    t.index ["company_id"], name: "index_buyer_portal_accesses_on_company_id"
    t.index ["email"], name: "index_buyer_portal_accesses_on_email", unique: true
    t.index ["invitation_token"], name: "index_buyer_portal_accesses_on_invitation_token", unique: true
    t.index ["login_token"], name: "index_buyer_portal_accesses_on_login_token"
    t.index ["reset_token"], name: "index_buyer_portal_accesses_on_reset_token"
    t.index ["status"], name: "index_buyer_portal_accesses_on_status"
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
    t.text "subject"
    t.text "body", null: false
    t.json "variables", default: "{}"
    t.boolean "is_active", default: true
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "template_type", default: "general"
    t.boolean "is_default", default: false
    t.integer "company_id"
    t.index ["channel"], name: "index_communication_templates_on_channel"
    t.index ["company_id"], name: "index_communication_templates_on_company_id"
    t.index ["is_active"], name: "index_communication_templates_on_is_active"
    t.index ["name"], name: "index_communication_templates_on_name"
    t.index ["template_type", "channel"], name: "idx_comm_templates_type_channel_scope"
    t.index ["template_type"], name: "index_communication_templates_on_template_type"
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
    t.datetime "read_at"
    t.datetime "received_at"
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
    t.string "domain"
    t.string "subdomain"
    t.string "custom_domain"
    t.datetime "domain_verified_at"
    t.string "domain_verification_token"
    t.string "email_domain"
    t.datetime "email_domain_verified_at"
    t.string "status", default: "active"
    t.datetime "trial_ends_at"
    t.string "subscription_tier"
    t.integer "max_users"
    t.integer "max_storage_gb"
    t.string "zoho_subscription_id"
    t.string "zoho_customer_id"
    t.boolean "use_rbac_system", default: false, null: false
    t.jsonb "loan_settings", default: {}, null: false
    t.string "external_payments_id"
    t.index ["custom_domain"], name: "index_companies_on_custom_domain"
    t.index ["domain"], name: "index_companies_on_domain", unique: true
    t.index ["external_payments_id"], name: "index_companies_on_external_payments_id"
    t.index ["loan_settings"], name: "index_companies_on_loan_settings", using: :gin
    t.index ["status"], name: "index_companies_on_status"
    t.index ["subdomain"], name: "index_companies_on_subdomain", unique: true
    t.index ["subscription_tier"], name: "index_companies_on_subscription_tier"
    t.index ["use_rbac_system"], name: "index_companies_on_use_rbac_system"
  end

  create_table "company_hidden_roles", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "role_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "role_id"], name: "index_company_hidden_roles_on_company_and_role", unique: true
    t.index ["company_id"], name: "index_company_hidden_roles_on_company_id"
    t.index ["role_id"], name: "index_company_hidden_roles_on_role_id"
  end

  create_table "contact_activities", force: :cascade do |t|
    t.integer "contact_id", null: false
    t.integer "account_id"
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
    t.index ["account_id", "activity_type"], name: "index_contact_activities_on_account_id_and_activity_type"
    t.index ["account_id"], name: "index_contact_activities_on_account_id"
    t.index ["assigned_to_id", "status"], name: "index_contact_activities_on_assigned_to_id_and_status"
    t.index ["assigned_to_id"], name: "index_contact_activities_on_assigned_to_id"
    t.index ["contact_id", "activity_type"], name: "index_contact_activities_on_contact_id_and_activity_type"
    t.index ["contact_id"], name: "index_contact_activities_on_contact_id"
    t.index ["due_date"], name: "index_contact_activities_on_due_date"
    t.index ["related_activity_id"], name: "index_contact_activities_on_related_activity_id"
    t.index ["start_time"], name: "index_contact_activities_on_start_time"
    t.index ["user_id"], name: "index_contact_activities_on_user_id"
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
    t.boolean "opt_out_email", default: false, null: false
    t.datetime "opt_out_email_at"
    t.boolean "opt_out_sms", default: false, null: false
    t.datetime "opt_out_sms_at"
    t.bigint "location_id"
    t.string "street"
    t.string "city"
    t.string "state"
    t.string "zip"
    t.string "country"
    t.index ["account_id"], name: "index_contacts_on_account_id"
    t.index ["company_id", "location_id"], name: "index_contacts_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_contacts_on_company_id"
    t.index ["location_id"], name: "index_contacts_on_location_id"
    t.index ["opt_out_email"], name: "index_contacts_on_opt_out_email"
    t.index ["opt_out_sms"], name: "index_contacts_on_opt_out_sms"
  end

  create_table "custom_fields", force: :cascade do |t|
    t.integer "company_id", null: false
    t.string "module", null: false
    t.string "name", null: false
    t.string "label", null: false
    t.string "field_type", null: false
    t.boolean "required", default: false
    t.string "default_value"
    t.text "options"
    t.integer "display_order", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "module", "name"], name: "index_custom_fields_on_company_module_name", unique: true
    t.index ["company_id", "module"], name: "index_custom_fields_on_company_id_and_module"
    t.index ["company_id"], name: "index_custom_fields_on_company_id"
  end

  create_table "deal_products", force: :cascade do |t|
    t.integer "deal_id", null: false
    t.integer "product_id"
    t.string "product_name"
    t.string "product_sku"
    t.integer "quantity", default: 1
    t.decimal "unit_price", precision: 12, scale: 2, default: "0.0"
    t.decimal "discount", precision: 12, scale: 2, default: "0.0"
    t.decimal "tax", precision: 12, scale: 2, default: "0.0"
    t.decimal "total", precision: 12, scale: 2, default: "0.0"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["deal_id", "product_id"], name: "index_deal_products_on_deal_id_and_product_id"
    t.index ["deal_id"], name: "index_deal_products_on_deal_id"
    t.index ["product_id"], name: "index_deal_products_on_product_id"
  end

  create_table "deal_stage_histories", force: :cascade do |t|
    t.integer "deal_id", null: false
    t.string "stage", null: false
    t.string "previous_stage"
    t.integer "changed_by_id"
    t.integer "duration"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["changed_by_id"], name: "index_deal_stage_histories_on_changed_by_id"
    t.index ["deal_id", "created_at"], name: "index_deal_stage_histories_on_deal_id_and_created_at"
    t.index ["deal_id"], name: "index_deal_stage_histories_on_deal_id"
    t.index ["stage"], name: "index_deal_stage_histories_on_stage"
  end

  create_table "deals", force: :cascade do |t|
    t.string "name", null: false
    t.integer "account_id"
    t.decimal "value", precision: 12, scale: 2, default: "0.0"
    t.string "stage", default: "qualification", null: false
    t.integer "probability", default: 0
    t.date "expected_close_date"
    t.date "actual_close_date"
    t.integer "user_id"
    t.integer "territory_id"
    t.string "lead_source"
    t.text "description"
    t.text "notes"
    t.datetime "won_at"
    t.datetime "lost_at"
    t.string "win_reason"
    t.string "loss_reason"
    t.string "competitor"
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "contact_id"
    t.integer "vehicle_id"
    t.string "customer_name"
    t.integer "source_id"
    t.string "assigned_to"
    t.integer "company_id"
    t.bigint "location_id"
    t.index ["account_id", "stage"], name: "index_deals_on_account_id_and_stage"
    t.index ["account_id"], name: "index_deals_on_account_id"
    t.index ["assigned_to"], name: "index_deals_on_assigned_to"
    t.index ["company_id", "location_id"], name: "index_deals_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_deals_on_company_id"
    t.index ["contact_id"], name: "index_deals_on_contact_id"
    t.index ["deleted_at"], name: "index_deals_on_deleted_at"
    t.index ["expected_close_date"], name: "index_deals_on_expected_close_date"
    t.index ["location_id"], name: "index_deals_on_location_id"
    t.index ["lost_at"], name: "index_deals_on_lost_at"
    t.index ["source_id"], name: "index_deals_on_source_id"
    t.index ["stage"], name: "index_deals_on_stage"
    t.index ["territory_id", "stage"], name: "index_deals_on_territory_id_and_stage"
    t.index ["territory_id"], name: "index_deals_on_territory_id"
    t.index ["user_id", "stage"], name: "index_deals_on_user_id_and_stage"
    t.index ["user_id"], name: "index_deals_on_user_id"
    t.index ["vehicle_id"], name: "index_deals_on_vehicle_id"
    t.index ["won_at"], name: "index_deals_on_won_at"
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

  create_table "invitations", force: :cascade do |t|
    t.string "invitation_type", null: false
    t.string "token_digest", null: false
    t.string "email", null: false
    t.string "phone"
    t.string "status", default: "pending", null: false
    t.string "recipient_name"
    t.json "recipient_data", default: {}
    t.integer "invited_by_id", null: false
    t.integer "company_id"
    t.string "role"
    t.json "permissions", default: []
    t.string "delivery_method", null: false
    t.datetime "sent_at"
    t.datetime "delivered_at"
    t.datetime "viewed_at"
    t.datetime "accepted_at"
    t.datetime "expires_at", null: false
    t.integer "resend_count", default: 0
    t.datetime "last_sent_at"
    t.string "ip_address"
    t.string "user_agent"
    t.integer "attempts", default: 0
    t.text "message"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "location_ids", default: [], null: false
    t.string "location_role", default: "location_staff"
    t.index ["company_id", "status"], name: "index_invitations_on_company_id_and_status"
    t.index ["company_id"], name: "index_invitations_on_company_id"
    t.index ["email"], name: "index_invitations_on_email"
    t.index ["expires_at"], name: "index_invitations_on_expires_at"
    t.index ["invitation_type", "status"], name: "index_invitations_on_invitation_type_and_status"
    t.index ["invited_by_id"], name: "index_invitations_on_invited_by_id"
    t.index ["location_role"], name: "index_invitations_on_location_role"
    t.index ["status"], name: "index_invitations_on_status"
    t.index ["token_digest"], name: "index_invitations_on_token_digest", unique: true
  end

  create_table "invoice_items", force: :cascade do |t|
    t.bigint "invoice_id", null: false
    t.string "item_type"
    t.string "description", null: false
    t.decimal "quantity", precision: 10, scale: 2, default: "1.0"
    t.decimal "rate", precision: 10, scale: 2, null: false
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.bigint "listing_id"
    t.integer "position", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["invoice_id", "position"], name: "index_invoice_items_on_invoice_id_and_position"
    t.index ["invoice_id"], name: "index_invoice_items_on_invoice_id"
    t.index ["listing_id"], name: "index_invoice_items_on_listing_id"
  end

  create_table "invoices", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.bigint "contact_id", null: false
    t.bigint "listing_id"
    t.bigint "deal_id"
    t.string "invoice_number", null: false
    t.string "status", default: "draft"
    t.date "invoice_date", null: false
    t.date "due_date"
    t.decimal "subtotal", precision: 10, scale: 2, default: "0.0"
    t.decimal "tax_rate", precision: 5, scale: 2, default: "0.0"
    t.decimal "tax_amount", precision: 10, scale: 2, default: "0.0"
    t.decimal "total", precision: 10, scale: 2, default: "0.0"
    t.decimal "amount_paid", precision: 10, scale: 2, default: "0.0"
    t.decimal "amount_due", precision: 10, scale: 2, default: "0.0"
    t.text "notes"
    t.text "terms"
    t.text "footer_text"
    t.string "payment_token"
    t.datetime "sent_at"
    t.datetime "viewed_at"
    t.datetime "paid_at"
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "invoice_number"], name: "index_invoices_on_company_id_and_invoice_number", unique: true
    t.index ["company_id"], name: "index_invoices_on_company_id"
    t.index ["contact_id"], name: "index_invoices_on_contact_id"
    t.index ["deal_id"], name: "index_invoices_on_deal_id"
    t.index ["due_date"], name: "index_invoices_on_due_date"
    t.index ["listing_id"], name: "index_invoices_on_listing_id"
    t.index ["location_id"], name: "index_invoices_on_location_id"
    t.index ["payment_token"], name: "index_invoices_on_payment_token", unique: true
    t.index ["status"], name: "index_invoices_on_status"
  end

  create_table "land_parcels", force: :cascade do |t|
    t.integer "company_id", null: false
    t.string "parcel_number", null: false
    t.string "name"
    t.string "address"
    t.string "city"
    t.string "state"
    t.string "zip"
    t.string "county"
    t.decimal "latitude", precision: 10, scale: 8
    t.decimal "longitude", precision: 11, scale: 8
    t.decimal "acreage", precision: 10, scale: 4
    t.string "zoning_type"
    t.string "status", default: "available", null: false
    t.decimal "price", precision: 15, scale: 2
    t.decimal "price_per_acre", precision: 15, scale: 2
    t.json "utilities", default: {}
    t.json "features", default: []
    t.string "owner_name"
    t.string "owner_phone"
    t.string "owner_email"
    t.date "acquisition_date"
    t.text "description"
    t.text "notes"
    t.json "images", default: []
    t.json "documents", default: []
    t.boolean "is_deleted", default: false, null: false
    t.datetime "deleted_at"
    t.integer "created_by"
    t.integer "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "cost_basis", precision: 15, scale: 2
    t.text "cost_basis_notes"
    t.text "boundary_geojson"
    t.decimal "boundary_area_sq_ft", precision: 12, scale: 2
    t.boolean "has_boundary", default: false, null: false
    t.index ["acquisition_date"], name: "index_land_parcels_on_acquisition_date"
    t.index ["city", "state"], name: "index_land_parcels_on_city_and_state"
    t.index ["company_id", "parcel_number"], name: "index_land_parcels_on_company_id_and_parcel_number", unique: true
    t.index ["company_id"], name: "index_land_parcels_on_company_id"
    t.index ["has_boundary"], name: "index_land_parcels_on_has_boundary"
    t.index ["is_deleted"], name: "index_land_parcels_on_is_deleted"
    t.index ["status"], name: "index_land_parcels_on_status"
    t.index ["zoning_type"], name: "index_land_parcels_on_zoning_type"
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
    t.bigint "location_id"
    t.index ["company_id", "location_id"], name: "index_leads_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_leads_on_company_id"
    t.index ["converted_account_id"], name: "index_leads_on_converted_account_id"
    t.index ["location_id"], name: "index_leads_on_location_id"
    t.index ["source_id"], name: "index_leads_on_source_id"
  end

  create_table "listings", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "vehicle_id", null: false
    t.string "status", default: "draft", null: false
    t.string "offer_type", null: false
    t.decimal "sale_price", precision: 12, scale: 2
    t.decimal "rent_price", precision: 10, scale: 2
    t.string "rent_period"
    t.text "description"
    t.text "features"
    t.jsonb "additional_features", default: {}
    t.string "package_type"
    t.string "location_type"
    t.string "community_name"
    t.decimal "lot_rent", precision: 10, scale: 2
    t.string "financing_available"
    t.string "delivery_available"
    t.string "setup_included"
    t.boolean "has_garage", default: false
    t.boolean "has_fireplace", default: false
    t.boolean "has_deck", default: false
    t.boolean "has_shed", default: false
    t.boolean "has_appliances", default: false
    t.boolean "has_ac", default: false
    t.boolean "is_furnished", default: false
    t.boolean "pets_allowed", default: false
    t.string "seller_name"
    t.string "seller_phone"
    t.string "seller_email"
    t.string "agent_name"
    t.string "agent_phone"
    t.string "agent_email"
    t.datetime "published_at"
    t.datetime "last_synced_at"
    t.jsonb "syndication_metadata", default: {}
    t.boolean "is_deleted", default: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "property_name"
    t.jsonb "office_hours", default: {}
    t.jsonb "parking_details", default: {}
    t.jsonb "pet_policy", default: {}
    t.text "concessions"
    t.text "promotional_text"
    t.decimal "security_deposit", precision: 10, scale: 2
    t.decimal "application_fee", precision: 10, scale: 2
    t.decimal "admin_fee", precision: 10, scale: 2
    t.string "lease_terms"
    t.date "available_date"
    t.decimal "effective_rent", precision: 10, scale: 2
    t.jsonb "property_amenities", default: []
    t.jsonb "unit_amenities", default: []
    t.decimal "latitude", precision: 10, scale: 6
    t.decimal "longitude", precision: 10, scale: 6
    t.string "unit_number"
    t.string "floor_plan_name"
    t.decimal "pet_deposit", precision: 10, scale: 2
    t.decimal "key_deposit", precision: 10, scale: 2
    t.decimal "other_deposit", precision: 10, scale: 2
    t.string "other_deposit_description"
    t.decimal "pet_rent", precision: 10, scale: 2
    t.decimal "parking_fee", precision: 10, scale: 2
    t.decimal "storage_fee", precision: 10, scale: 2
    t.decimal "trash_fee", precision: 10, scale: 2
    t.jsonb "utilities_included", default: {}
    t.integer "min_lease_term"
    t.integer "max_lease_term"
    t.string "lease_type"
    t.integer "floor_number"
    t.string "unit_type"
    t.text "specials_description"
    t.string "move_in_date_type", default: "specific_date"
    t.boolean "immediately_available", default: false
    t.decimal "income_requirement_multiplier", precision: 3, scale: 1
    t.boolean "credit_check_required", default: true
    t.boolean "background_check_required", default: true
    t.bigint "location_id"
    t.index ["available_date"], name: "index_listings_on_available_date"
    t.index ["company_id", "is_deleted"], name: "index_listings_on_company_id_and_is_deleted"
    t.index ["company_id", "location_id"], name: "index_listings_on_company_id_and_location_id"
    t.index ["company_id", "property_name"], name: "index_listings_on_company_id_and_property_name"
    t.index ["company_id", "status"], name: "index_listings_on_company_id_and_status"
    t.index ["company_id"], name: "index_listings_on_company_id"
    t.index ["floor_number"], name: "index_listings_on_floor_number"
    t.index ["immediately_available"], name: "index_listings_on_immediately_available"
    t.index ["location_id"], name: "index_listings_on_location_id"
    t.index ["offer_type"], name: "index_listings_on_offer_type"
    t.index ["published_at"], name: "index_listings_on_published_at"
    t.index ["status"], name: "index_listings_on_status"
    t.index ["unit_number"], name: "index_listings_on_unit_number"
    t.index ["unit_type"], name: "index_listings_on_unit_type"
    t.index ["vehicle_id"], name: "index_listings_on_vehicle_id"
  end

  create_table "loans", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "loan_number", null: false
    t.string "loan_type"
    t.string "status", default: "pending", null: false
    t.string "borrower_type", null: false
    t.bigint "borrower_id", null: false
    t.string "financed_entity_type"
    t.bigint "financed_entity_id"
    t.decimal "principal_amount", precision: 12, scale: 2, null: false
    t.decimal "interest_rate", precision: 5, scale: 2
    t.integer "term_months"
    t.date "origination_date", null: false
    t.date "maturity_date"
    t.date "first_payment_date"
    t.string "payment_frequency", default: "monthly"
    t.decimal "regular_payment_amount", precision: 10, scale: 2
    t.integer "day_of_month_due"
    t.decimal "current_balance", precision: 12, scale: 2, default: "0.0"
    t.decimal "total_paid", precision: 12, scale: 2, default: "0.0"
    t.decimal "total_interest_paid", precision: 12, scale: 2, default: "0.0"
    t.integer "payments_made", default: 0
    t.integer "payments_remaining"
    t.date "last_payment_date"
    t.date "next_payment_date"
    t.integer "days_past_due", default: 0
    t.decimal "late_fees_assessed", precision: 10, scale: 2, default: "0.0"
    t.bigint "default_payment_method_id"
    t.boolean "auto_pay_enabled", default: false
    t.string "external_loan_id"
    t.text "notes"
    t.jsonb "metadata", default: {}
    t.boolean "is_deleted", default: false
    t.datetime "deleted_at"
    t.string "created_by"
    t.string "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "origination_fee", precision: 10, scale: 2, default: "0.0"
    t.index ["borrower_type", "borrower_id"], name: "index_loans_on_borrower"
    t.index ["company_id", "is_deleted"], name: "index_loans_on_company_id_and_is_deleted"
    t.index ["company_id", "loan_number"], name: "index_loans_on_company_id_and_loan_number", unique: true
    t.index ["company_id", "status"], name: "index_loans_on_company_id_and_status"
    t.index ["company_id"], name: "index_loans_on_company_id"
    t.index ["default_payment_method_id"], name: "index_loans_on_default_payment_method_id"
    t.index ["financed_entity_type", "financed_entity_id"], name: "index_loans_on_financed_entity"
    t.index ["location_id"], name: "index_loans_on_location_id"
    t.index ["next_payment_date"], name: "index_loans_on_next_payment_date"
    t.index ["status"], name: "index_loans_on_status"
  end

  create_table "location_activities", force: :cascade do |t|
    t.bigint "location_id", null: false
    t.bigint "user_id"
    t.string "action", null: false
    t.string "category", null: false
    t.text "description"
    t.jsonb "metadata", default: {}
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["action"], name: "index_location_activities_on_action"
    t.index ["category"], name: "index_location_activities_on_category"
    t.index ["location_id", "occurred_at"], name: "index_location_activities_on_location_id_and_occurred_at"
    t.index ["location_id"], name: "index_location_activities_on_location_id"
    t.index ["occurred_at"], name: "index_location_activities_on_occurred_at"
    t.index ["user_id"], name: "index_location_activities_on_user_id"
  end

  create_table "locations", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.string "code", limit: 10
    t.text "description"
    t.string "phone"
    t.string "email"
    t.string "address_line1"
    t.string "address_line2"
    t.string "city"
    t.string "state"
    t.string "zip_code"
    t.string "country", default: "US"
    t.string "timezone", default: "America/New_York"
    t.jsonb "business_hours", default: {}
    t.decimal "delivery_radius_miles", precision: 10, scale: 2
    t.jsonb "branding_settings", default: {}
    t.jsonb "communication_settings", default: {}
    t.jsonb "operational_settings", default: {}
    t.jsonb "integration_settings", default: {}
    t.boolean "active", default: true, null: false
    t.boolean "is_deleted", default: false, null: false
    t.datetime "deleted_at"
    t.string "created_by"
    t.string "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "external_payments_property_id"
    t.index ["active"], name: "index_locations_on_active"
    t.index ["company_id", "active"], name: "index_locations_on_company_id_and_active"
    t.index ["company_id", "code"], name: "index_locations_on_company_id_and_code", unique: true, where: "(code IS NOT NULL)"
    t.index ["company_id", "is_deleted"], name: "index_locations_on_company_id_and_is_deleted"
    t.index ["company_id"], name: "index_locations_on_company_id"
    t.index ["deleted_at"], name: "index_locations_on_deleted_at"
    t.index ["external_payments_property_id"], name: "index_locations_on_external_payments_property_id"
  end

  create_table "lot_map_history_entries", force: :cascade do |t|
    t.integer "lot_id", null: false
    t.string "action", null: false
    t.integer "inventory_id"
    t.string "old_status"
    t.string "new_status"
    t.integer "user_id"
    t.string "user_name"
    t.text "details"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["action"], name: "index_lot_map_history_entries_on_action"
    t.index ["created_at"], name: "index_lot_map_history_entries_on_created_at"
    t.index ["inventory_id"], name: "index_lot_map_history_entries_on_inventory_id"
    t.index ["lot_id"], name: "index_lot_map_history_entries_on_lot_id"
    t.index ["user_id"], name: "index_lot_map_history_entries_on_user_id"
  end

  create_table "lot_map_layouts", force: :cascade do |t|
    t.integer "company_id", null: false
    t.string "name", null: false
    t.string "address"
    t.decimal "latitude", precision: 10, scale: 6
    t.decimal "longitude", precision: 10, scale: 6
    t.json "boundary", default: "{}"
    t.integer "lot_count", default: 0
    t.boolean "detected_from_satellite", default: false
    t.string "industry_type"
    t.string "created_by"
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "deleted_at"], name: "index_lot_map_layouts_on_company_id_and_deleted_at"
    t.index ["company_id"], name: "index_lot_map_layouts_on_company_id"
    t.index ["industry_type"], name: "index_lot_map_layouts_on_industry_type"
    t.index ["name"], name: "index_lot_map_layouts_on_name"
  end

  create_table "lot_map_lots", force: :cascade do |t|
    t.integer "layout_id", null: false
    t.string "number", null: false
    t.json "position", default: "{}"
    t.integer "assigned_inventory_id"
    t.string "assigned_inventory_info"
    t.string "area"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["assigned_inventory_id"], name: "index_lot_map_lots_on_assigned_inventory_id"
    t.index ["layout_id", "number"], name: "index_lot_map_lots_on_layout_id_and_number", unique: true
    t.index ["layout_id"], name: "index_lot_map_lots_on_layout_id"
    t.index ["number"], name: "index_lot_map_lots_on_number"
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
    t.bigint "company_id"
    t.index ["company_id"], name: "index_nurture_enrollments_on_company_id"
    t.index ["enrollable_type", "enrollable_id"], name: "index_nurture_enrollments_on_enrollable_type_and_enrollable_id"
    t.index ["lead_id", "nurture_sequence_id"], name: "idx_unique_active_enrollment", unique: true, where: "((status)::text = ANY ((ARRAY['running'::character varying, 'paused'::character varying])::text[]))"
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
    t.bigint "company_id"
    t.index ["company_id"], name: "index_nurture_sequences_on_company_id"
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

  create_table "password_reset_tokens", force: :cascade do |t|
    t.string "token_digest", null: false
    t.string "identifier", null: false
    t.string "user_type", null: false
    t.integer "user_id"
    t.string "delivery_method", null: false
    t.datetime "expires_at", null: false
    t.boolean "used", default: false
    t.string "ip_address"
    t.string "user_agent"
    t.integer "attempts", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_password_reset_tokens_on_expires_at"
    t.index ["identifier", "created_at"], name: "index_password_reset_tokens_on_identifier_and_created_at"
    t.index ["token_digest"], name: "index_password_reset_tokens_on_token_digest", unique: true
    t.index ["user_id", "user_type"], name: "index_password_reset_tokens_on_user_id_and_user_type"
  end

  create_table "payment_methods", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "owner_type", null: false
    t.bigint "owner_id", null: false
    t.string "method_type", null: false
    t.string "nickname"
    t.string "ach_account_type"
    t.string "ach_routing_number_encrypted"
    t.string "ach_account_number_encrypted"
    t.string "ach_last_4"
    t.string "credit_card_number_encrypted"
    t.string "credit_card_last_4"
    t.string "credit_card_brand"
    t.integer "credit_card_exp_month"
    t.integer "credit_card_exp_year"
    t.string "credit_card_cvv_encrypted"
    t.boolean "is_debit_card", default: false
    t.string "billing_first_name"
    t.string "billing_last_name"
    t.string "billing_street"
    t.string "billing_city"
    t.string "billing_state"
    t.string "billing_zip"
    t.string "billing_country", default: "US"
    t.string "external_id"
    t.string "alternate_external_id"
    t.integer "api_partner_id"
    t.boolean "is_default", default: false
    t.boolean "is_active", default: true
    t.boolean "is_verified", default: false
    t.datetime "verified_at"
    t.boolean "is_deleted", default: false
    t.datetime "deleted_at"
    t.string "created_by"
    t.string "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "is_deleted"], name: "index_payment_methods_on_company_id_and_is_deleted"
    t.index ["company_id"], name: "index_payment_methods_on_company_id"
    t.index ["external_id"], name: "index_payment_methods_on_external_id"
    t.index ["location_id"], name: "index_payment_methods_on_location_id"
    t.index ["method_type"], name: "index_payment_methods_on_method_type"
    t.index ["owner_type", "owner_id", "is_default"], name: "idx_on_owner_type_owner_id_is_default_59ae03cd28"
    t.index ["owner_type", "owner_id"], name: "index_payment_methods_on_owner"
  end

  create_table "payments", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "payment_number", null: false
    t.string "payment_type", null: false
    t.string "status", default: "pending", null: false
    t.bigint "loan_id"
    t.bigint "payment_method_id"
    t.string "payer_type", null: false
    t.bigint "payer_id", null: false
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.decimal "principal_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "interest_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "fee_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "late_fee_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "processing_fee", precision: 10, scale: 2, default: "0.0"
    t.string "fee_responsibility"
    t.string "fee_type"
    t.decimal "fee_value", precision: 10, scale: 2
    t.decimal "total_charged", precision: 12, scale: 2
    t.datetime "scheduled_at"
    t.datetime "processed_at"
    t.date "payment_date"
    t.string "external_id"
    t.string "gateway_name"
    t.text "gateway_response"
    t.string "failure_reason"
    t.boolean "is_refunded", default: false
    t.decimal "refund_amount", precision: 12, scale: 2
    t.datetime "refunded_at"
    t.string "refund_reason"
    t.text "notes"
    t.jsonb "metadata", default: {}
    t.boolean "is_deleted", default: false
    t.datetime "deleted_at"
    t.string "created_by"
    t.string "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "payable_type"
    t.bigint "payable_id"
    t.index ["company_id", "is_deleted"], name: "index_payments_on_company_id_and_is_deleted"
    t.index ["company_id", "payment_number"], name: "index_payments_on_company_id_and_payment_number", unique: true
    t.index ["company_id", "status"], name: "index_payments_on_company_id_and_status"
    t.index ["company_id"], name: "index_payments_on_company_id"
    t.index ["external_id"], name: "index_payments_on_external_id"
    t.index ["loan_id", "payment_date"], name: "index_payments_on_loan_id_and_payment_date"
    t.index ["loan_id"], name: "index_payments_on_loan_id"
    t.index ["location_id"], name: "index_payments_on_location_id"
    t.index ["payable_type", "payable_id"], name: "index_payments_on_payable_type_and_payable_id"
    t.index ["payer_type", "payer_id"], name: "index_payments_on_payer"
    t.index ["payment_date"], name: "index_payments_on_payment_date"
    t.index ["payment_method_id"], name: "index_payments_on_payment_method_id"
    t.index ["scheduled_at"], name: "index_payments_on_scheduled_at"
    t.index ["status"], name: "index_payments_on_status"
  end

  create_table "portal_documents", force: :cascade do |t|
    t.string "owner_type", null: false
    t.bigint "owner_id", null: false
    t.string "category"
    t.text "description"
    t.string "related_to_type"
    t.bigint "related_to_id"
    t.string "uploaded_by", default: "buyer"
    t.datetime "uploaded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "document_name"
    t.text "notes"
    t.text "admin_notes"
    t.index ["category"], name: "index_portal_documents_on_category"
    t.index ["owner_type", "owner_id"], name: "index_portal_documents_on_owner"
    t.index ["related_to_type", "related_to_id"], name: "index_portal_documents_on_related_to"
    t.index ["uploaded_at"], name: "index_portal_documents_on_uploaded_at"
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
    t.integer "resend_count", default: 0, null: false
    t.datetime "last_sent_at"
    t.integer "company_id"
    t.bigint "location_id"
    t.index ["account_id"], name: "index_quotes_on_account_id"
    t.index ["company_id", "location_id"], name: "index_quotes_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_quotes_on_company_id"
    t.index ["contact_id"], name: "index_quotes_on_contact_id"
    t.index ["created_at"], name: "index_quotes_on_created_at"
    t.index ["customer_id"], name: "index_quotes_on_customer_id"
    t.index ["is_deleted"], name: "index_quotes_on_is_deleted"
    t.index ["location_id"], name: "index_quotes_on_location_id"
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

  create_table "resources", force: :cascade do |t|
    t.string "key", limit: 100, null: false
    t.string "name", null: false
    t.text "description"
    t.string "category", limit: 50
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_resources_on_active"
    t.index ["category"], name: "index_resources_on_category"
    t.index ["key"], name: "index_resources_on_key", unique: true
  end

  create_table "role_permissions", force: :cascade do |t|
    t.bigint "role_id", null: false
    t.bigint "resource_id", null: false
    t.bigint "action_id", null: false
    t.bigint "scope_id", null: false
    t.boolean "granted", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["action_id"], name: "index_role_permissions_on_action_id"
    t.index ["resource_id"], name: "index_role_permissions_on_resource_id"
    t.index ["role_id", "granted"], name: "index_role_permissions_granted"
    t.index ["role_id", "resource_id", "action_id", "scope_id"], name: "index_role_permissions_unique", unique: true
    t.index ["role_id"], name: "index_role_permissions_on_role_id"
    t.index ["scope_id"], name: "index_role_permissions_on_scope_id"
  end

  create_table "roles", force: :cascade do |t|
    t.bigint "company_id"
    t.string "tier", limit: 50, null: false
    t.string "key", limit: 100, null: false
    t.string "name", null: false
    t.text "description"
    t.boolean "is_system_role", default: false, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "color"
    t.index ["active"], name: "index_roles_on_active"
    t.index ["company_id", "tier", "key"], name: "index_roles_unique_per_company", unique: true
    t.index ["company_id"], name: "index_roles_on_company_id"
    t.index ["is_system_role"], name: "index_roles_on_is_system_role"
    t.index ["tier"], name: "index_roles_on_tier"
  end

  create_table "scopes", force: :cascade do |t|
    t.string "key", limit: 100, null: false
    t.string "name", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_scopes_on_key", unique: true
  end

  create_table "service_tickets", force: :cascade do |t|
    t.integer "company_id", null: false
    t.integer "account_id"
    t.integer "contact_id"
    t.integer "vehicle_id"
    t.string "customer_id"
    t.string "customer_type"
    t.string "title", null: false
    t.text "description"
    t.string "priority", default: "medium", null: false
    t.string "status", default: "open", null: false
    t.string "assigned_to"
    t.date "scheduled_date"
    t.date "completed_date"
    t.text "parts"
    t.text "labor"
    t.text "notes"
    t.text "custom_fields"
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "location_id"
    t.index ["account_id"], name: "index_service_tickets_on_account_id"
    t.index ["assigned_to"], name: "index_service_tickets_on_assigned_to"
    t.index ["company_id", "location_id"], name: "index_service_tickets_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_service_tickets_on_company_id"
    t.index ["contact_id"], name: "index_service_tickets_on_contact_id"
    t.index ["customer_type", "customer_id"], name: "index_service_tickets_on_customer_type_and_customer_id"
    t.index ["deleted_at"], name: "index_service_tickets_on_deleted_at"
    t.index ["location_id"], name: "index_service_tickets_on_location_id"
    t.index ["priority"], name: "index_service_tickets_on_priority"
    t.index ["scheduled_date"], name: "index_service_tickets_on_scheduled_date"
    t.index ["status"], name: "index_service_tickets_on_status"
    t.index ["vehicle_id"], name: "index_service_tickets_on_vehicle_id"
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
    t.bigint "company_id"
    t.index ["company_id", "name"], name: "index_sources_on_company_id_and_name"
    t.index ["company_id"], name: "index_sources_on_company_id"
  end

  create_table "syndication_partners", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.string "partner_type", null: false
    t.string "format", default: "json", null: false
    t.text "listing_types", default: [], array: true
    t.string "feed_url"
    t.string "account_id"
    t.string "lead_email"
    t.string "contact_name"
    t.string "contact_phone"
    t.boolean "active", default: true
    t.datetime "last_synced_at"
    t.jsonb "settings", default: {}
    t.jsonb "sync_metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "api_key"
    t.string "webhook_url"
    t.string "feed_token"
    t.string "sync_status"
    t.text "sync_error"
    t.index ["active"], name: "index_syndication_partners_on_active"
    t.index ["company_id", "active"], name: "index_syndication_partners_on_company_id_and_active"
    t.index ["company_id", "partner_type"], name: "index_syndication_partners_on_company_id_and_partner_type"
    t.index ["company_id"], name: "index_syndication_partners_on_company_id"
    t.index ["feed_token"], name: "index_syndication_partners_on_feed_token", unique: true
    t.index ["partner_type"], name: "index_syndication_partners_on_partner_type"
  end

  create_table "tag_assignments", force: :cascade do |t|
    t.integer "tag_id", null: false
    t.string "entity_type", null: false
    t.string "entity_id", null: false
    t.string "assigned_by"
    t.datetime "assigned_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "company_id"
    t.index ["company_id"], name: "index_tag_assignments_on_company_id"
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
    t.bigint "company_id"
    t.index ["category"], name: "index_tags_on_category"
    t.index ["company_id", "name"], name: "index_tags_on_company_id_and_name"
    t.index ["company_id", "name"], name: "index_tags_unique_per_company", unique: true, where: "(company_id IS NOT NULL)"
    t.index ["company_id"], name: "index_tags_on_company_id"
  end

  create_table "templates", force: :cascade do |t|
    t.string "name", null: false
    t.string "template_type", null: false
    t.string "subject"
    t.text "body"
    t.boolean "is_active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "company_id", null: false
    t.index ["company_id"], name: "index_templates_on_company_id"
    t.index ["template_type", "name"], name: "index_templates_on_template_type_and_name"
  end

  create_table "territories", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.integer "user_id"
    t.string "region"
    t.string "type_field"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "is_active", default: true, null: false
    t.bigint "company_id"
    t.index ["company_id", "name"], name: "index_territories_on_company_id_and_name"
    t.index ["company_id", "name"], name: "index_territories_unique_per_company", unique: true, where: "(company_id IS NOT NULL)"
    t.index ["company_id"], name: "index_territories_on_company_id"
    t.index ["user_id"], name: "index_territories_on_user_id"
  end

  create_table "territory_rules", force: :cascade do |t|
    t.integer "territory_id", null: false
    t.string "field", null: false
    t.string "operator", null: false
    t.string "value"
    t.integer "priority", default: 0
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_territory_rules_on_active"
    t.index ["territory_id", "priority"], name: "index_territory_rules_on_territory_id_and_priority"
    t.index ["territory_id"], name: "index_territory_rules_on_territory_id"
  end

  create_table "territory_users", force: :cascade do |t|
    t.integer "territory_id", null: false
    t.integer "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["territory_id", "user_id"], name: "index_territory_users_on_territory_id_and_user_id", unique: true
    t.index ["territory_id"], name: "index_territory_users_on_territory_id"
    t.index ["user_id"], name: "index_territory_users_on_user_id"
  end

  create_table "user_locations", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "location_id", null: false
    t.bigint "company_id", null: false
    t.string "location_role", default: "location_staff"
    t.boolean "active", default: true, null: false
    t.string "assigned_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_user_locations_on_active"
    t.index ["company_id", "location_id"], name: "index_user_locations_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_user_locations_on_company_id"
    t.index ["location_id"], name: "index_user_locations_on_location_id"
    t.index ["user_id", "location_id"], name: "index_user_locations_on_user_id_and_location_id", unique: true
    t.index ["user_id"], name: "index_user_locations_on_user_id"
  end

  create_table "user_role_assignments", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "role_id", null: false
    t.string "tier", limit: 50, null: false
    t.bigint "region_id"
    t.bigint "location_id"
    t.bigint "assigned_by_id"
    t.datetime "assigned_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "company_id", null: false
    t.index ["company_id"], name: "index_user_role_assignments_on_company_id"
    t.index ["expires_at"], name: "index_user_role_assignments_on_expires_at"
    t.index ["location_id"], name: "index_user_role_assignments_on_location_id"
    t.index ["region_id"], name: "index_user_role_assignments_on_region_id"
    t.index ["role_id"], name: "index_user_role_assignments_on_role_id"
    t.index ["tier"], name: "index_user_role_assignments_on_tier"
    t.index ["user_id", "role_id", "tier", "region_id", "location_id"], name: "index_user_role_assignments_unique", unique: true
    t.index ["user_id"], name: "index_user_role_assignments_on_user_id"
    t.check_constraint "tier::text = 'company'::text AND region_id IS NULL AND location_id IS NULL OR tier::text = 'region'::text AND region_id IS NOT NULL AND location_id IS NULL OR tier::text = 'location'::text AND location_id IS NOT NULL", name: "check_tier_assignment"
  end

  create_table "users", force: :cascade do |t|
    t.string "email"
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "password_digest"
    t.string "role", default: "staff"
    t.string "first_name"
    t.string "last_name"
    t.string "status", default: "pending"
    t.datetime "last_sign_in_at"
    t.json "permissions", default: []
    t.string "phone"
    t.string "magic_link_token"
    t.datetime "magic_link_expires_at"
    t.boolean "mfa_enabled", default: false
    t.string "mfa_secret"
    t.json "mfa_backup_codes", default: []
    t.datetime "mfa_verified_at"
    t.integer "invitation_id"
    t.datetime "deleted_at"
    t.text "deleted_reason"
    t.boolean "phone_verified", default: false, null: false
    t.string "mfa_sms_code"
    t.datetime "mfa_sms_expires_at"
    t.string "mfa_method", default: "sms"
    t.integer "company_id"
    t.string "title"
    t.string "department"
    t.string "invitation_token"
    t.datetime "invitation_sent_at"
    t.datetime "invitation_expires_at"
    t.index ["company_id"], name: "index_users_on_company_id"
    t.index ["deleted_at"], name: "index_users_on_deleted_at"
    t.index ["email", "invitation_id"], name: "index_users_on_email_and_invitation_id"
    t.index ["invitation_id"], name: "index_users_on_invitation_id"
    t.index ["invitation_token"], name: "index_users_on_invitation_token", unique: true
    t.index ["magic_link_token"], name: "index_users_on_magic_link_token", unique: true
    t.index ["mfa_enabled"], name: "index_users_on_mfa_enabled"
    t.index ["mfa_method"], name: "index_users_on_mfa_method"
    t.index ["mfa_sms_expires_at"], name: "index_users_on_mfa_sms_expires_at"
    t.index ["phone"], name: "index_users_on_phone"
    t.index ["phone_verified"], name: "index_users_on_phone_verified"
  end

  create_table "vehicles", force: :cascade do |t|
    t.integer "company_id"
    t.string "stock_number"
    t.string "vin"
    t.integer "year"
    t.string "make"
    t.string "model"
    t.string "trim"
    t.string "color"
    t.string "condition", default: "new"
    t.string "status", default: "available"
    t.decimal "cost", precision: 15, scale: 2
    t.integer "mileage"
    t.text "description"
    t.text "notes"
    t.json "features", default: []
    t.string "location"
    t.datetime "date_in_stock"
    t.datetime "date_sold"
    t.boolean "is_deleted", default: false, null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "listing_type", default: "rv", null: false
    t.string "inventory_id"
    t.string "serial_number"
    t.integer "bedrooms"
    t.decimal "bathrooms", precision: 3, scale: 1
    t.integer "length"
    t.integer "width"
    t.integer "square_feet"
    t.string "location_city"
    t.string "location_state"
    t.string "location_zip"
    t.decimal "rent_price", precision: 15, scale: 2
    t.decimal "sale_price", precision: 15, scale: 2
    t.json "images", default: []
    t.string "body_style"
    t.string "fuel_type"
    t.string "transmission"
    t.integer "sleeps"
    t.integer "weight"
    t.string "home_type"
    t.string "roof_type"
    t.string "siding_type"
    t.decimal "lot_rent", precision: 10, scale: 2
    t.string "community_name"
    t.integer "width1"
    t.integer "length1"
    t.integer "width2"
    t.integer "length2"
    t.integer "width3"
    t.integer "length3"
    t.boolean "garage", default: false
    t.boolean "carport", default: false
    t.boolean "deck", default: false
    t.boolean "patio", default: false
    t.boolean "fireplace", default: false
    t.boolean "central_air", default: false
    t.string "mileage_unit"
    t.string "exterior_color"
    t.string "interior_color"
    t.string "vehicle_interior_type"
    t.string "vehicle_configuration"
    t.string "rv_type"
    t.string "slide_outs"
    t.boolean "awning", default: false
    t.boolean "generator", default: false
    t.string "number_of_doors"
    t.integer "seating_capacity"
    t.decimal "msrp", precision: 15, scale: 2
    t.string "price_currency", default: "USD"
    t.string "seller_name"
    t.string "seller_phone"
    t.string "seller_address_street"
    t.string "seller_address_city"
    t.string "seller_address_state"
    t.string "seller_address_zip"
    t.string "listing_url"
    t.json "videos", default: []
    t.string "dwelling_type"
    t.string "foundation_type"
    t.string "flooring_type"
    t.string "heating_type"
    t.string "cooling_type"
    t.string "water_heater_type"
    t.json "appliances", default: []
    t.string "master_bedroom_location"
    t.decimal "rent_to_own_price", precision: 15, scale: 2
    t.decimal "deposit_amount", precision: 15, scale: 2
    t.string "location_type"
    t.string "community_key"
    t.string "address1"
    t.string "address2"
    t.string "county_name"
    t.string "exterior_material"
    t.string "roof_material"
    t.string "insulation_type"
    t.string "ceiling_type"
    t.string "wall_type"
    t.boolean "has_storage", default: false
    t.boolean "thermopane", default: false
    t.boolean "gutters", default: false
    t.boolean "shutters", default: false
    t.boolean "cathedral_ceiling", default: false
    t.boolean "ceiling_fan", default: false
    t.boolean "skylight", default: false
    t.boolean "walkin_closet", default: false
    t.boolean "laundry_room", default: false
    t.boolean "pantry", default: false
    t.boolean "sun_room", default: false
    t.boolean "basement", default: false
    t.boolean "garden_tub", default: false
    t.boolean "garbage_disposal", default: false
    t.boolean "refrigerator", default: false
    t.boolean "microwave", default: false
    t.boolean "oven", default: false
    t.boolean "dishwasher", default: false
    t.boolean "clothes_washer", default: false
    t.boolean "clothes_dryer", default: false
    t.decimal "utilities", precision: 10, scale: 2
    t.text "terms"
    t.boolean "repo", default: false
    t.string "package_type"
    t.boolean "sale_pending", default: false
    t.string "photo_url"
    t.string "virtual_tour"
    t.string "sales_photo"
    t.bigint "location_id"
    t.index ["body_style"], name: "index_vehicles_on_body_style"
    t.index ["company_id", "inventory_id"], name: "index_vehicles_on_company_id_and_inventory_id", unique: true
    t.index ["company_id", "location_id"], name: "index_vehicles_on_company_id_and_location_id"
    t.index ["company_id", "serial_number"], name: "index_vehicles_on_company_id_and_serial_number", unique: true, where: "(serial_number IS NOT NULL)"
    t.index ["company_id", "vin"], name: "index_vehicles_on_company_id_and_vin", unique: true, where: "(vin IS NOT NULL)"
    t.index ["company_id"], name: "index_vehicles_on_company_id"
    t.index ["condition"], name: "index_vehicles_on_condition"
    t.index ["dwelling_type"], name: "index_vehicles_on_dwelling_type"
    t.index ["exterior_color"], name: "index_vehicles_on_exterior_color"
    t.index ["home_type"], name: "index_vehicles_on_home_type"
    t.index ["is_deleted"], name: "index_vehicles_on_is_deleted"
    t.index ["listing_type"], name: "index_vehicles_on_listing_type"
    t.index ["location_id"], name: "index_vehicles_on_location_id"
    t.index ["rv_type"], name: "index_vehicles_on_rv_type"
    t.index ["status"], name: "index_vehicles_on_status"
    t.index ["year", "make", "model"], name: "index_vehicles_on_year_and_make_and_model"
  end

  create_table "win_loss_reports", force: :cascade do |t|
    t.integer "deal_id", null: false
    t.string "result", null: false
    t.string "primary_reason"
    t.string "secondary_reason"
    t.string "competitor"
    t.text "competitive_advantage"
    t.text "competitive_disadvantage"
    t.text "customer_feedback"
    t.text "internal_notes"
    t.text "lessons_learned"
    t.integer "deal_quality_score"
    t.integer "sales_process_score"
    t.integer "product_fit_score"
    t.integer "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["competitor"], name: "index_win_loss_reports_on_competitor"
    t.index ["deal_id", "result"], name: "index_win_loss_reports_on_deal_id_and_result"
    t.index ["deal_id"], name: "index_win_loss_reports_on_deal_id"
    t.index ["primary_reason"], name: "index_win_loss_reports_on_primary_reason"
    t.index ["result"], name: "index_win_loss_reports_on_result"
    t.index ["user_id"], name: "index_win_loss_reports_on_user_id"
  end

  add_foreign_key "accounts", "accounts", column: "parent_account_id"
  add_foreign_key "accounts", "companies"
  add_foreign_key "accounts", "locations"
  add_foreign_key "accounts", "sources"
  add_foreign_key "accounts", "users", column: "owner_id"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "activities", "leads"
  add_foreign_key "activities", "users"
  add_foreign_key "ai_insights", "leads"
  add_foreign_key "api_logs", "companies"
  add_foreign_key "approval_actions", "approval_steps"
  add_foreign_key "approval_actions", "users"
  add_foreign_key "approval_steps", "approval_workflows"
  add_foreign_key "approval_steps", "users", column: "approver_user_id"
  add_foreign_key "approval_workflows", "deals"
  add_foreign_key "approval_workflows", "users", column: "approved_by_id"
  add_foreign_key "approval_workflows", "users", column: "requested_by_id"
  add_foreign_key "bank_accounts", "companies"
  add_foreign_key "bank_accounts", "locations"
  add_foreign_key "brochures", "companies"
  add_foreign_key "communication_events", "communications"
  add_foreign_key "communications", "communication_templates", column: "template_id"
  add_foreign_key "communications", "communication_threads"
  add_foreign_key "company_hidden_roles", "companies"
  add_foreign_key "company_hidden_roles", "roles"
  add_foreign_key "contact_activities", "accounts"
  add_foreign_key "contact_activities", "contact_activities", column: "related_activity_id"
  add_foreign_key "contact_activities", "contacts"
  add_foreign_key "contact_activities", "users"
  add_foreign_key "contact_activities", "users", column: "assigned_to_id"
  add_foreign_key "contacts", "locations"
  add_foreign_key "custom_fields", "companies"
  add_foreign_key "deal_products", "deals"
  add_foreign_key "deal_stage_histories", "deals"
  add_foreign_key "deal_stage_histories", "users", column: "changed_by_id"
  add_foreign_key "deals", "accounts"
  add_foreign_key "deals", "companies"
  add_foreign_key "deals", "contacts"
  add_foreign_key "deals", "locations"
  add_foreign_key "deals", "sources"
  add_foreign_key "deals", "users"
  add_foreign_key "intake_forms", "companies"
  add_foreign_key "intake_forms", "sources"
  add_foreign_key "intake_submissions", "leads"
  add_foreign_key "invitations", "companies"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "invoice_items", "invoices"
  add_foreign_key "invoice_items", "listings"
  add_foreign_key "invoices", "companies"
  add_foreign_key "invoices", "contacts"
  add_foreign_key "invoices", "deals"
  add_foreign_key "invoices", "listings"
  add_foreign_key "invoices", "locations"
  add_foreign_key "land_parcels", "companies"
  add_foreign_key "lead_activities", "lead_activities", column: "related_activity_id"
  add_foreign_key "lead_activities", "leads"
  add_foreign_key "lead_activities", "users"
  add_foreign_key "lead_activities", "users", column: "assigned_to_id"
  add_foreign_key "lead_scores", "leads"
  add_foreign_key "lead_tasks", "leads"
  add_foreign_key "leads", "accounts", column: "converted_account_id"
  add_foreign_key "leads", "companies"
  add_foreign_key "leads", "locations"
  add_foreign_key "leads", "sources"
  add_foreign_key "listings", "companies"
  add_foreign_key "listings", "locations"
  add_foreign_key "listings", "vehicles"
  add_foreign_key "loans", "companies"
  add_foreign_key "loans", "locations"
  add_foreign_key "loans", "payment_methods", column: "default_payment_method_id"
  add_foreign_key "location_activities", "locations"
  add_foreign_key "location_activities", "users"
  add_foreign_key "locations", "companies"
  add_foreign_key "lot_map_history_entries", "lot_map_lots", column: "lot_id"
  add_foreign_key "lot_map_history_entries", "users"
  add_foreign_key "lot_map_history_entries", "vehicles", column: "inventory_id"
  add_foreign_key "lot_map_layouts", "companies"
  add_foreign_key "lot_map_lots", "lot_map_layouts", column: "layout_id"
  add_foreign_key "lot_map_lots", "vehicles", column: "assigned_inventory_id"
  add_foreign_key "notes", "users"
  add_foreign_key "nurture_enrollments", "companies"
  add_foreign_key "nurture_enrollments", "leads"
  add_foreign_key "nurture_enrollments", "nurture_sequences"
  add_foreign_key "nurture_sequences", "companies"
  add_foreign_key "nurture_steps", "nurture_sequences"
  add_foreign_key "nurture_steps", "templates"
  add_foreign_key "payment_methods", "companies"
  add_foreign_key "payment_methods", "locations"
  add_foreign_key "payments", "companies"
  add_foreign_key "payments", "loans"
  add_foreign_key "payments", "locations"
  add_foreign_key "payments", "payment_methods"
  add_foreign_key "quotes", "accounts"
  add_foreign_key "quotes", "contacts"
  add_foreign_key "quotes", "locations"
  add_foreign_key "reminders", "leads"
  add_foreign_key "reminders", "users"
  add_foreign_key "role_permissions", "actions", on_delete: :cascade
  add_foreign_key "role_permissions", "resources", on_delete: :cascade
  add_foreign_key "role_permissions", "roles", on_delete: :cascade
  add_foreign_key "role_permissions", "scopes", on_delete: :cascade
  add_foreign_key "roles", "companies", on_delete: :cascade
  add_foreign_key "service_tickets", "accounts"
  add_foreign_key "service_tickets", "companies"
  add_foreign_key "service_tickets", "contacts"
  add_foreign_key "service_tickets", "locations"
  add_foreign_key "service_tickets", "vehicles"
  add_foreign_key "syndication_partners", "companies"
  add_foreign_key "tag_assignments", "tags"
  add_foreign_key "templates", "companies"
  add_foreign_key "territories", "users"
  add_foreign_key "territory_rules", "territories"
  add_foreign_key "territory_users", "territories"
  add_foreign_key "territory_users", "users"
  add_foreign_key "user_locations", "companies"
  add_foreign_key "user_locations", "locations"
  add_foreign_key "user_locations", "users"
  add_foreign_key "user_role_assignments", "companies", on_delete: :cascade
  add_foreign_key "user_role_assignments", "roles", on_delete: :cascade
  add_foreign_key "user_role_assignments", "users", column: "assigned_by_id", on_delete: :nullify
  add_foreign_key "user_role_assignments", "users", on_delete: :cascade
  add_foreign_key "users", "companies"
  add_foreign_key "users", "invitations"
  add_foreign_key "vehicles", "companies"
  add_foreign_key "vehicles", "locations"
  add_foreign_key "win_loss_reports", "deals"
  add_foreign_key "win_loss_reports", "users"
end
