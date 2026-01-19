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

ActiveRecord::Schema[8.0].define(version: 2026_01_19_013500) do
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

  create_table "bins", force: :cascade do |t|
    t.bigint "location_id", null: false
    t.string "bin_code", null: false
    t.string "label"
    t.string "bin_type", default: "standard"
    t.decimal "capacity_cubic_feet", precision: 10, scale: 2
    t.text "notes"
    t.boolean "is_default", default: false
    t.boolean "active", default: true
    t.boolean "is_deleted", default: false
    t.datetime "deleted_at"
    t.jsonb "custom_fields", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bin_type"], name: "index_bins_on_bin_type"
    t.index ["location_id", "active"], name: "index_bins_on_location_id_and_active"
    t.index ["location_id", "bin_code"], name: "index_bins_on_location_id_and_bin_code", unique: true, where: "(is_deleted = false)"
    t.index ["location_id", "is_default"], name: "index_bins_on_location_id_and_is_default"
    t.index ["location_id"], name: "index_bins_on_location_id"
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
    t.boolean "mfa_enabled", default: false
    t.string "mfa_method"
    t.index ["buyer_type", "buyer_id", "company_id"], name: "index_buyer_portal_on_buyer_and_company"
    t.index ["buyer_type", "buyer_id"], name: "index_buyer_portal_accesses_on_buyer"
    t.index ["company_id"], name: "index_buyer_portal_accesses_on_company_id"
    t.index ["email"], name: "index_buyer_portal_accesses_on_email", unique: true
    t.index ["invitation_token"], name: "index_buyer_portal_accesses_on_invitation_token", unique: true
    t.index ["login_token"], name: "index_buyer_portal_accesses_on_login_token"
    t.index ["mfa_enabled"], name: "index_buyer_portal_accesses_on_mfa_enabled"
    t.index ["reset_token"], name: "index_buyer_portal_accesses_on_reset_token"
    t.index ["status"], name: "index_buyer_portal_accesses_on_status"
  end

  create_table "commission_audit_entries", force: :cascade do |t|
    t.bigint "commission_id", null: false
    t.bigint "user_id", null: false
    t.string "action", null: false
    t.jsonb "previous_value"
    t.jsonb "new_value"
    t.text "notes"
    t.datetime "created_at", precision: nil, null: false
    t.index ["action"], name: "index_commission_audit_entries_on_action"
    t.index ["commission_id", "created_at"], name: "index_commission_audit_entries_on_commission_id_and_created_at"
    t.index ["commission_id"], name: "index_commission_audit_entries_on_commission_id"
    t.index ["user_id"], name: "index_commission_audit_entries_on_user_id"
  end

  create_table "commission_components", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "name", null: false
    t.string "component_type", null: false
    t.string "applies_to_role", null: false
    t.boolean "is_active", default: true
    t.string "gross_type"
    t.decimal "rate", precision: 8, scale: 6
    t.decimal "flat_amount", precision: 15, scale: 2
    t.integer "units_threshold"
    t.string "threshold_period"
    t.string "deal_type"
    t.string "vertical"
    t.integer "sequence", default: 0
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "commission_plan_id"
    t.index ["applies_to_role"], name: "index_commission_components_on_role"
    t.index ["commission_plan_id"], name: "index_commission_components_on_commission_plan_id"
    t.index ["company_id", "is_active"], name: "index_commission_components_on_company_and_active"
    t.index ["company_id", "location_id", "is_active", "sequence"], name: "index_commission_components_lookup"
    t.index ["company_id"], name: "index_commission_components_on_company_id"
    t.index ["component_type"], name: "index_commission_components_on_type"
    t.index ["location_id"], name: "index_commission_components_on_location_id"
  end

  create_table "commission_payment_line_items", force: :cascade do |t|
    t.bigint "commission_payment_id", null: false
    t.bigint "commission_component_id"
    t.string "description", null: false, comment: "Display name of commission component"
    t.string "calculation_basis", null: false, comment: "What amount was used as basis (front_gross, back_gross, etc.)"
    t.string "calculation_method", null: false, comment: "How it was calculated (flat_rate, percentage, tiered, per_unit)"
    t.decimal "rate", precision: 8, scale: 4, comment: "Rate used (percentage or per-unit amount)"
    t.decimal "basis_amount", precision: 15, scale: 2, default: "0.0", null: false, comment: "Dollar amount commission was calculated on"
    t.decimal "calculated_amount", precision: 15, scale: 2, null: false, comment: "Commission earned from this component"
    t.integer "display_order", default: 0
    t.jsonb "calculation_details", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["calculation_basis"], name: "index_commission_payment_line_items_on_calculation_basis"
    t.index ["calculation_method"], name: "index_commission_payment_line_items_on_calculation_method"
    t.index ["commission_component_id"], name: "index_commission_payment_line_items_on_commission_component_id"
    t.index ["commission_payment_id", "display_order"], name: "index_comm_line_items_on_payment_and_order"
    t.index ["commission_payment_id"], name: "index_comm_line_items_on_payment_id"
  end

  create_table "commission_payments", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.bigint "deal_id", null: false
    t.bigint "payee_user_id", null: false
    t.string "payment_number", null: false
    t.string "status", default: "pending", null: false
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.jsonb "calculation_details", default: {}
    t.bigint "approved_by_user_id"
    t.datetime "approved_at"
    t.bigint "paid_by_user_id"
    t.datetime "paid_at"
    t.string "payment_method"
    t.string "payment_reference"
    t.boolean "is_reversed", default: false
    t.bigint "reversed_by_user_id"
    t.datetime "reversed_at"
    t.text "reversal_reason"
    t.text "notes"
    t.jsonb "metadata", default: {}
    t.boolean "is_deleted", default: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "commission_plan_id"
    t.date "earned_date"
    t.decimal "amount_paid", precision: 10, scale: 2
    t.decimal "remaining_balance", precision: 10, scale: 2
    t.date "paid_date"
    t.index ["approved_at"], name: "index_commission_payments_approved_at"
    t.index ["approved_by_user_id"], name: "index_commission_payments_on_approved_by_user_id"
    t.index ["commission_plan_id"], name: "index_commission_payments_on_commission_plan_id"
    t.index ["company_id", "payment_number"], name: "index_commission_payments_unique_number", unique: true
    t.index ["company_id", "status"], name: "index_commission_payments_status"
    t.index ["company_id"], name: "index_commission_payments_on_company_id"
    t.index ["deal_id"], name: "index_commission_payments_deal"
    t.index ["deal_id"], name: "index_commission_payments_on_deal_id"
    t.index ["earned_date"], name: "index_commission_payments_on_earned_date"
    t.index ["is_deleted"], name: "index_commission_payments_deleted"
    t.index ["location_id"], name: "index_commission_payments_on_location_id"
    t.index ["paid_at"], name: "index_commission_payments_paid_at"
    t.index ["paid_by_user_id"], name: "index_commission_payments_on_paid_by_user_id"
    t.index ["payee_user_id", "status"], name: "index_commission_payments_payee_status"
    t.index ["payee_user_id"], name: "index_commission_payments_on_payee_user_id"
    t.index ["reversed_by_user_id"], name: "index_commission_payments_on_reversed_by_user_id"
  end

  create_table "commission_plans", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "name", null: false
    t.text "description"
    t.bigint "assigned_user_id", comment: "If set, plan only applies to this specific user"
    t.string "assigned_role", comment: "If set, plan applies to users with this role"
    t.date "effective_date", default: -> { "CURRENT_DATE" }, null: false
    t.date "expiration_date", comment: "NULL = no expiration"
    t.boolean "is_active", default: true, null: false
    t.boolean "is_default", default: false, null: false, comment: "Company-wide default plan (no user/role filter)"
    t.integer "display_order", default: 0
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["assigned_role"], name: "index_commission_plans_on_assigned_role", where: "(assigned_role IS NOT NULL)"
    t.index ["assigned_user_id"], name: "index_commission_plans_on_assigned_user_id", where: "(assigned_user_id IS NOT NULL)"
    t.index ["company_id", "is_active"], name: "index_commission_plans_on_company_id_and_is_active"
    t.index ["company_id", "is_default"], name: "index_commission_plans_on_company_id_and_is_default"
    t.index ["company_id"], name: "index_commission_plans_on_company_id"
    t.index ["effective_date", "expiration_date"], name: "index_commission_plans_on_effective_date_and_expiration_date"
    t.index ["location_id"], name: "index_commission_plans_on_location_id"
  end

  create_table "commission_rules", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.string "rule_type", null: false
    t.decimal "rate", precision: 5, scale: 4
    t.decimal "amount", precision: 10, scale: 2
    t.jsonb "tiers", default: []
    t.boolean "is_active", default: true
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "is_active"], name: "index_commission_rules_on_company_id_and_is_active"
    t.index ["company_id"], name: "index_commission_rules_on_company_id"
    t.index ["rule_type"], name: "index_commission_rules_on_rule_type"
  end

  create_table "commissions", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "deal_id", null: false
    t.bigint "user_id", null: false
    t.bigint "commission_rule_id"
    t.bigint "location_id"
    t.string "commission_type", null: false
    t.decimal "rate", precision: 5, scale: 4
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.string "status", default: "pending", null: false
    t.date "paid_date"
    t.text "notes"
    t.jsonb "custom_fields", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["commission_rule_id"], name: "index_commissions_on_commission_rule_id"
    t.index ["commission_type"], name: "index_commissions_on_commission_type"
    t.index ["company_id", "status"], name: "index_commissions_on_company_id_and_status"
    t.index ["deal_id"], name: "index_commissions_on_deal_id"
    t.index ["location_id"], name: "index_commissions_on_location_id"
    t.index ["paid_date"], name: "index_commissions_on_paid_date"
    t.index ["user_id", "status"], name: "index_commissions_on_user_id_and_status"
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
    t.boolean "use_rbac_system", default: true, null: false
    t.jsonb "loan_settings", default: {}, null: false
    t.string "external_payments_id"
    t.jsonb "branding_settings", default: {}
    t.boolean "filter_assignments_by_role", default: false, null: false, comment: "When true, users can only be assigned to records within their role department"
    t.string "quickbooks_realm_id"
    t.datetime "quickbooks_connected_at"
    t.text "quickbooks_access_token_encrypted"
    t.text "quickbooks_refresh_token_encrypted"
    t.datetime "quickbooks_token_expires_at"
    t.datetime "quickbooks_last_sync_at"
    t.boolean "quickbooks_sync_enabled", default: false
    t.string "quickbooks_scope", default: "company", null: false
    t.jsonb "quickbooks_settings", default: {}
    t.decimal "default_pack_amount", precision: 15, scale: 2, default: "0.0"
    t.integer "fiscal_year_start_month", default: 1, null: false, comment: "Month when fiscal year starts (1=January, 2=February, etc.). Used for quarterly commission calculations. Default is 1 (January) for calendar year."
    t.boolean "is_demo", default: false, null: false
    t.index ["custom_domain"], name: "index_companies_on_custom_domain"
    t.index ["default_pack_amount"], name: "index_companies_on_default_pack_amount"
    t.index ["domain"], name: "index_companies_on_domain", unique: true
    t.index ["external_payments_id"], name: "index_companies_on_external_payments_id"
    t.index ["is_demo"], name: "index_companies_on_is_demo"
    t.index ["loan_settings"], name: "index_companies_on_loan_settings", using: :gin
    t.index ["quickbooks_realm_id"], name: "index_companies_on_quickbooks_realm_id"
    t.index ["quickbooks_scope"], name: "index_companies_on_quickbooks_scope"
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

  create_table "company_manufacturers", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "manufacturer_id", null: false
    t.string "dealer_code"
    t.boolean "active", default: true, null: false
    t.text "notes"
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_company_manufacturers_on_active"
    t.index ["company_id", "manufacturer_id"], name: "index_company_manufacturers_on_company_and_manufacturer", unique: true
    t.index ["company_id"], name: "index_company_manufacturers_on_company_id"
    t.index ["manufacturer_id"], name: "index_company_manufacturers_on_manufacturer_id"
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
    t.integer "owner_id"
    t.string "quickbooks_id"
    t.datetime "quickbooks_synced_at"
    t.boolean "is_deleted", default: false, null: false
    t.string "company_name"
    t.index ["account_id"], name: "index_contacts_on_account_id"
    t.index ["company_id", "location_id"], name: "index_contacts_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_contacts_on_company_id"
    t.index ["is_deleted"], name: "index_contacts_on_is_deleted"
    t.index ["location_id"], name: "index_contacts_on_location_id"
    t.index ["opt_out_email"], name: "index_contacts_on_opt_out_email"
    t.index ["opt_out_sms"], name: "index_contacts_on_opt_out_sms"
    t.index ["owner_id"], name: "index_contacts_on_owner_id"
    t.index ["quickbooks_id"], name: "index_contacts_on_quickbooks_id"
  end

  create_table "custom_field_permissions", force: :cascade do |t|
    t.bigint "custom_field_id", null: false
    t.bigint "role_id", null: false
    t.string "permission_level", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["custom_field_id", "role_id"], name: "index_custom_field_permissions_on_custom_field_id_and_role_id", unique: true
    t.index ["custom_field_id"], name: "index_custom_field_permissions_on_custom_field_id"
    t.index ["role_id"], name: "index_custom_field_permissions_on_role_id"
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
    t.string "field_key", null: false
    t.text "description"
    t.string "placeholder"
    t.jsonb "validation_rules", default: {}
    t.boolean "is_active", default: true
    t.boolean "is_system_field", default: false
    t.string "section"
    t.bigint "created_by_id"
    t.bigint "updated_by_id"
    t.index ["company_id", "module", "field_key"], name: "index_custom_fields_on_company_module_field_key", unique: true
    t.index ["company_id", "module", "is_active"], name: "index_custom_fields_on_company_id_and_module_and_is_active"
    t.index ["company_id", "module", "name"], name: "index_custom_fields_on_company_module_name", unique: true
    t.index ["company_id", "module", "section"], name: "index_custom_fields_on_company_id_and_module_and_section"
    t.index ["company_id", "module"], name: "index_custom_fields_on_company_id_and_module"
    t.index ["company_id"], name: "index_custom_fields_on_company_id"
    t.index ["created_by_id"], name: "index_custom_fields_on_created_by_id"
    t.index ["field_key"], name: "index_custom_fields_on_field_key"
    t.index ["updated_by_id"], name: "index_custom_fields_on_updated_by_id"
  end

  create_table "custom_view_columns", force: :cascade do |t|
    t.bigint "custom_view_id", null: false
    t.string "field_key", null: false
    t.boolean "is_custom_field", default: false
    t.integer "display_order", default: 0
    t.integer "width_pixels"
    t.boolean "is_visible", default: true
    t.boolean "is_sortable", default: true
    t.boolean "is_filterable", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["custom_view_id", "display_order"], name: "index_custom_view_columns_on_custom_view_id_and_display_order"
    t.index ["custom_view_id", "field_key"], name: "index_custom_view_columns_on_custom_view_id_and_field_key", unique: true
    t.index ["custom_view_id"], name: "index_custom_view_columns_on_custom_view_id"
  end

  create_table "custom_views", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.string "module", null: false
    t.string "view_type", default: "table"
    t.boolean "is_default", default: false
    t.boolean "is_shared", default: false
    t.jsonb "filters", default: {}
    t.jsonb "sort_config", default: {}
    t.bigint "created_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "module", "is_default"], name: "index_custom_views_on_company_id_and_module_and_is_default"
    t.index ["company_id", "module"], name: "index_custom_views_on_company_id_and_module"
    t.index ["company_id"], name: "index_custom_views_on_company_id"
    t.index ["created_by_id", "module"], name: "index_custom_views_on_created_by_id_and_module"
    t.index ["created_by_id"], name: "index_custom_views_on_created_by_id"
  end

  create_table "dashboard_layouts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "company_id", null: false
    t.string "preset_id", null: false
    t.jsonb "layout_data", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_dashboard_layouts_on_company_id"
    t.index ["user_id", "company_id", "preset_id"], name: "index_dashboard_layouts_on_user_company_preset", unique: true
    t.index ["user_id"], name: "index_dashboard_layouts_on_user_id"
  end

  create_table "deal_activities", force: :cascade do |t|
    t.bigint "deal_id", null: false
    t.bigint "user_id"
    t.bigint "assigned_to_id"
    t.bigint "related_activity_id"
    t.string "activity_type", null: false
    t.string "subject"
    t.text "description"
    t.string "status"
    t.string "priority"
    t.datetime "due_date"
    t.datetime "start_time"
    t.datetime "end_time"
    t.datetime "completed_at"
    t.string "phone_number"
    t.string "call_direction"
    t.string "call_outcome"
    t.integer "duration"
    t.string "location"
    t.string "meeting_link"
    t.text "attendees"
    t.string "outcome"
    t.datetime "reminder_time"
    t.json "reminder_method"
    t.boolean "reminder_sent", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["activity_type"], name: "index_deal_activities_on_activity_type"
    t.index ["assigned_to_id"], name: "index_deal_activities_on_assigned_to_id"
    t.index ["deal_id"], name: "index_deal_activities_on_deal_id"
    t.index ["due_date"], name: "index_deal_activities_on_due_date"
    t.index ["priority"], name: "index_deal_activities_on_priority"
    t.index ["related_activity_id"], name: "index_deal_activities_on_related_activity_id"
    t.index ["reminder_time"], name: "index_deal_activities_on_reminder_time"
    t.index ["status"], name: "index_deal_activities_on_status"
    t.index ["user_id"], name: "index_deal_activities_on_user_id"
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
    t.integer "owner_id"
    t.decimal "selling_price", precision: 15, scale: 2
    t.decimal "unit_cost", precision: 15, scale: 2
    t.decimal "trade_allowance", precision: 15, scale: 2, default: "0.0"
    t.decimal "trade_payoff", precision: 15, scale: 2, default: "0.0"
    t.decimal "pack_amount", precision: 15, scale: 2
    t.decimal "finance_reserve", precision: 15, scale: 2, default: "0.0"
    t.decimal "product_margin", precision: 15, scale: 2, default: "0.0"
    t.decimal "accessories_total", precision: 15, scale: 2, default: "0.0"
    t.decimal "doc_fee", precision: 15, scale: 2, default: "0.0"
    t.decimal "delivery_fee", precision: 15, scale: 2, default: "0.0"
    t.decimal "setup_fee", precision: 15, scale: 2, default: "0.0"
    t.decimal "skirting_fee", precision: 15, scale: 2, default: "0.0"
    t.string "deal_type"
    t.string "vertical"
    t.integer "quantity", default: 1
    t.date "delivery_date"
    t.bigint "primary_salesperson_id"
    t.bigint "commission_plan_id"
    t.bigint "sales_manager_id"
    t.bigint "finance_manager_id"
    t.bigint "desk_manager_id"
    t.bigint "secondary_salesperson_id"
    t.index ["account_id", "stage"], name: "index_deals_on_account_id_and_stage"
    t.index ["account_id"], name: "index_deals_on_account_id"
    t.index ["assigned_to"], name: "index_deals_on_assigned_to"
    t.index ["commission_plan_id", "delivery_date"], name: "index_deals_on_plan_and_delivery"
    t.index ["commission_plan_id"], name: "index_deals_on_commission_plan_id"
    t.index ["company_id", "delivery_date"], name: "index_deals_on_company_and_delivery"
    t.index ["company_id", "location_id"], name: "index_deals_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_deals_on_company_id"
    t.index ["contact_id"], name: "index_deals_on_contact_id"
    t.index ["deal_type"], name: "index_deals_on_deal_type"
    t.index ["deleted_at"], name: "index_deals_on_deleted_at"
    t.index ["desk_manager_id"], name: "index_deals_on_desk_manager_id"
    t.index ["expected_close_date"], name: "index_deals_on_expected_close_date"
    t.index ["finance_manager_id"], name: "index_deals_on_finance_manager_id"
    t.index ["location_id"], name: "index_deals_on_location_id"
    t.index ["lost_at"], name: "index_deals_on_lost_at"
    t.index ["owner_id"], name: "index_deals_on_owner_id"
    t.index ["primary_salesperson_id", "delivery_date"], name: "index_deals_on_salesperson_and_delivery"
    t.index ["sales_manager_id"], name: "index_deals_on_sales_manager_id"
    t.index ["secondary_salesperson_id"], name: "index_deals_on_secondary_salesperson_id"
    t.index ["source_id"], name: "index_deals_on_source_id"
    t.index ["stage"], name: "index_deals_on_stage"
    t.index ["territory_id", "stage"], name: "index_deals_on_territory_id_and_stage"
    t.index ["territory_id"], name: "index_deals_on_territory_id"
    t.index ["user_id", "stage"], name: "index_deals_on_user_id_and_stage"
    t.index ["user_id"], name: "index_deals_on_user_id"
    t.index ["vehicle_id"], name: "index_deals_on_vehicle_id"
    t.index ["vertical"], name: "index_deals_on_vertical"
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

  create_table "inventory_transactions", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "part_id", null: false
    t.bigint "location_id", null: false
    t.bigint "bin_id"
    t.string "transaction_type", null: false
    t.decimal "quantity", precision: 10, scale: 3, null: false
    t.decimal "unit_cost", precision: 10, scale: 2
    t.bigint "source_transaction_id"
    t.string "serial_number"
    t.string "lot_number"
    t.date "lot_expiration_date"
    t.bigint "job_id"
    t.string "reference_type"
    t.bigint "reference_id"
    t.text "notes"
    t.string "transaction_number"
    t.bigint "created_by_id"
    t.datetime "transaction_date", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "purchase_order_line_id"
    t.index ["bin_id"], name: "index_inventory_transactions_on_bin_id"
    t.index ["company_id", "location_id"], name: "index_inventory_transactions_on_company_id_and_location_id"
    t.index ["company_id", "part_id"], name: "index_inventory_transactions_on_company_id_and_part_id"
    t.index ["company_id", "transaction_date"], name: "idx_on_company_id_transaction_date_85f55614ae"
    t.index ["company_id", "transaction_number"], name: "index_inventory_transactions_on_company_and_number", unique: true
    t.index ["company_id", "transaction_type"], name: "idx_on_company_id_transaction_type_49752ad940"
    t.index ["company_id"], name: "index_inventory_transactions_on_company_id"
    t.index ["created_by_id"], name: "index_inventory_transactions_on_created_by_id"
    t.index ["location_id"], name: "index_inventory_transactions_on_location_id"
    t.index ["lot_number"], name: "index_inventory_transactions_on_lot_number"
    t.index ["part_id"], name: "index_inventory_transactions_on_part_id"
    t.index ["purchase_order_line_id"], name: "index_inventory_transactions_on_purchase_order_line_id"
    t.index ["reference_type", "reference_id"], name: "idx_on_reference_type_reference_id_30e938d718"
    t.index ["serial_number"], name: "index_inventory_transactions_on_serial_number"
    t.index ["source_transaction_id"], name: "index_inventory_transactions_on_source_transaction_id"
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
    t.bigint "contact_id"
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
    t.string "source_type"
    t.bigint "source_id"
    t.string "billing_category"
    t.string "recipient_type"
    t.bigint "recipient_id"
    t.string "quickbooks_id"
    t.datetime "quickbooks_synced_at"
    t.integer "loan_id"
    t.integer "loan_payment_number"
    t.string "public_token"
    t.index ["billing_category"], name: "index_invoices_on_billing_category"
    t.index ["company_id", "invoice_number"], name: "index_invoices_on_company_id_and_invoice_number", unique: true
    t.index ["company_id"], name: "index_invoices_on_company_id"
    t.index ["contact_id"], name: "index_invoices_on_contact_id"
    t.index ["deal_id"], name: "index_invoices_on_deal_id"
    t.index ["due_date"], name: "index_invoices_on_due_date"
    t.index ["listing_id"], name: "index_invoices_on_listing_id"
    t.index ["loan_id", "loan_payment_number"], name: "index_invoices_on_loan_and_payment_number"
    t.index ["loan_id"], name: "index_invoices_on_loan_id"
    t.index ["location_id"], name: "index_invoices_on_location_id"
    t.index ["payment_token"], name: "index_invoices_on_payment_token", unique: true
    t.index ["public_token"], name: "index_invoices_on_public_token", unique: true
    t.index ["quickbooks_id"], name: "index_invoices_on_quickbooks_id"
    t.index ["recipient_type", "recipient_id"], name: "index_invoices_on_recipient_type_and_recipient_id"
    t.index ["source_type", "source_id"], name: "index_invoices_on_source_type_and_source_id"
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
    t.integer "owner_id"
    t.index ["company_id", "location_id"], name: "index_leads_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_leads_on_company_id"
    t.index ["converted_account_id"], name: "index_leads_on_converted_account_id"
    t.index ["location_id"], name: "index_leads_on_location_id"
    t.index ["owner_id"], name: "index_leads_on_owner_id"
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
    t.string "contact_email"
    t.string "contact_phone"
    t.index ["available_date"], name: "index_listings_on_available_date"
    t.index ["company_id", "is_deleted"], name: "index_listings_on_company_id_and_is_deleted"
    t.index ["company_id", "location_id"], name: "index_listings_on_company_id_and_location_id"
    t.index ["company_id", "property_name"], name: "index_listings_on_company_id_and_property_name"
    t.index ["company_id", "status"], name: "index_listings_on_company_id_and_status"
    t.index ["company_id"], name: "index_listings_on_company_id"
    t.index ["contact_email"], name: "index_listings_on_contact_email"
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
    t.decimal "current_period_paid", precision: 10, scale: 2, default: "0.0"
    t.decimal "current_period_late_fees", precision: 10, scale: 2, default: "0.0"
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

  create_table "location_manufacturers", force: :cascade do |t|
    t.bigint "location_id", null: false
    t.bigint "manufacturer_id", null: false
    t.string "dealer_code"
    t.boolean "active", default: true, null: false
    t.text "notes"
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_location_manufacturers_on_active"
    t.index ["location_id", "manufacturer_id"], name: "index_location_manufacturers_on_location_and_manufacturer", unique: true
    t.index ["location_id"], name: "index_location_manufacturers_on_location_id"
    t.index ["manufacturer_id"], name: "index_location_manufacturers_on_manufacturer_id"
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
    t.string "quickbooks_realm_id"
    t.datetime "quickbooks_connected_at"
    t.text "quickbooks_access_token_encrypted"
    t.text "quickbooks_refresh_token_encrypted"
    t.datetime "quickbooks_token_expires_at"
    t.datetime "quickbooks_last_sync_at"
    t.boolean "quickbooks_sync_enabled", default: false
    t.jsonb "quickbooks_settings", default: {}
    t.decimal "default_pack_amount", precision: 15, scale: 2
    t.integer "fiscal_year_start_month", comment: "Month when fiscal year starts (1=January, 2=February, etc.). Used for quarterly commission calculations. If NULL, falls back to company.fiscal_year_start_month. If both NULL, defaults to 1 (January) for calendar year."
    t.index ["active"], name: "index_locations_on_active"
    t.index ["company_id", "active"], name: "index_locations_on_company_id_and_active"
    t.index ["company_id", "code"], name: "index_locations_on_company_id_and_code", unique: true, where: "(code IS NOT NULL)"
    t.index ["company_id", "is_deleted"], name: "index_locations_on_company_id_and_is_deleted"
    t.index ["company_id"], name: "index_locations_on_company_id"
    t.index ["default_pack_amount"], name: "index_locations_on_default_pack_amount"
    t.index ["deleted_at"], name: "index_locations_on_deleted_at"
    t.index ["external_payments_property_id"], name: "index_locations_on_external_payments_property_id"
    t.index ["quickbooks_realm_id"], name: "index_locations_on_quickbooks_realm_id"
    t.index ["quickbooks_sync_enabled"], name: "index_locations_on_quickbooks_sync_enabled"
  end

  create_table "login_activities", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "user_type", default: "User", null: false
    t.string "ip_address"
    t.text "user_agent"
    t.datetime "logged_in_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["logged_in_at"], name: "index_login_activities_on_logged_in_at"
    t.index ["user_id", "user_type"], name: "index_login_activities_on_user_id_and_user_type"
    t.index ["user_id"], name: "index_login_activities_on_user_id"
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

  create_table "manufacturer_ar_payments", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "manufacturer_ar_transaction_id", null: false
    t.string "payment_number", null: false
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.date "payment_date", null: false
    t.string "payment_method"
    t.string "reference_number"
    t.text "notes"
    t.string "recorded_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "payment_number"], name: "idx_on_company_id_payment_number_3a93ea434b", unique: true
    t.index ["company_id"], name: "index_manufacturer_ar_payments_on_company_id"
    t.index ["manufacturer_ar_transaction_id"], name: "index_mfr_ar_payments_on_transaction_id"
    t.index ["payment_date"], name: "index_manufacturer_ar_payments_on_payment_date"
    t.index ["payment_method"], name: "index_manufacturer_ar_payments_on_payment_method"
  end

  create_table "manufacturer_ar_transactions", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.bigint "warranty_claim_id", null: false
    t.bigint "manufacturer_id", null: false
    t.string "transaction_number", null: false
    t.decimal "original_claim_amount", precision: 12, scale: 2, null: false
    t.decimal "amount_paid_to_date", precision: 12, scale: 2, default: "0.0"
    t.decimal "amount_outstanding", precision: 12, scale: 2, null: false
    t.string "status", default: "open", null: false
    t.date "claim_date"
    t.date "expected_payment_date"
    t.date "paid_in_full_date"
    t.text "notes"
    t.text "write_off_reason"
    t.boolean "is_deleted", default: false, null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["claim_date"], name: "index_manufacturer_ar_transactions_on_claim_date"
    t.index ["company_id", "status"], name: "index_manufacturer_ar_transactions_on_company_id_and_status"
    t.index ["company_id", "transaction_number"], name: "idx_on_company_id_transaction_number_c53913b19d", unique: true
    t.index ["company_id"], name: "index_manufacturer_ar_transactions_on_company_id"
    t.index ["expected_payment_date"], name: "index_manufacturer_ar_transactions_on_expected_payment_date"
    t.index ["location_id"], name: "index_manufacturer_ar_transactions_on_location_id"
    t.index ["manufacturer_id", "status"], name: "idx_on_manufacturer_id_status_a8bf3034f4"
    t.index ["manufacturer_id"], name: "index_manufacturer_ar_transactions_on_manufacturer_id"
    t.index ["status"], name: "index_manufacturer_ar_transactions_on_status"
    t.index ["warranty_claim_id"], name: "index_manufacturer_ar_transactions_on_warranty_claim_id"
  end

  create_table "manufacturer_claim_views", force: :cascade do |t|
    t.bigint "warranty_claim_id", null: false
    t.bigint "company_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "viewed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_manufacturer_claim_views_on_company_id"
    t.index ["warranty_claim_id", "viewed_at"], name: "idx_on_warranty_claim_id_viewed_at_560fa437c4"
    t.index ["warranty_claim_id"], name: "index_manufacturer_claim_views_on_warranty_claim_id"
  end

  create_table "manufacturers", force: :cascade do |t|
    t.string "name", null: false
    t.string "industry_type", null: false
    t.string "contact_email"
    t.string "contact_phone"
    t.string "website"
    t.jsonb "oem_codes", default: {}
    t.boolean "has_portal_access", default: false, null: false
    t.string "portal_url"
    t.boolean "active", default: true, null: false
    t.text "notes"
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active", "industry_type"], name: "index_manufacturers_on_active_and_industry_type"
    t.index ["active"], name: "index_manufacturers_on_active"
    t.index ["industry_type"], name: "index_manufacturers_on_industry_type"
    t.index ["name"], name: "index_manufacturers_on_name"
  end

  create_table "mfa_tokens", force: :cascade do |t|
    t.string "token_digest", null: false
    t.string "user_type", null: false
    t.bigint "user_id", null: false
    t.string "delivery_method", null: false
    t.string "identifier"
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.integer "attempts", default: 0, null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_mfa_tokens_on_created_at"
    t.index ["expires_at"], name: "index_mfa_tokens_on_expires_at"
    t.index ["identifier"], name: "index_mfa_tokens_on_identifier"
    t.index ["token_digest"], name: "index_mfa_tokens_on_token_digest", unique: true
    t.index ["user_id", "user_type", "used_at"], name: "index_mfa_tokens_on_user_id_and_user_type_and_used_at"
    t.index ["user_type", "user_id"], name: "index_mfa_tokens_on_user"
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

  create_table "notification_preferences", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "notification_type", null: false
    t.string "category", null: false
    t.boolean "in_app_enabled", default: true, null: false
    t.boolean "email_enabled", default: false, null: false
    t.boolean "sms_enabled", default: false, null: false
    t.string "frequency", default: "immediate"
    t.boolean "respect_quiet_hours", default: false
    t.time "quiet_hours_start"
    t.time "quiet_hours_end"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_notification_preferences_on_category"
    t.index ["user_id", "notification_type"], name: "index_notification_prefs_on_user_and_type", unique: true
  end

  create_table "notifications", force: :cascade do |t|
    t.string "recipient_type", null: false
    t.bigint "recipient_id", null: false
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "notification_type", null: false
    t.string "category", null: false
    t.string "priority", default: "normal"
    t.string "title", null: false
    t.text "message", null: false
    t.string "notifiable_type"
    t.bigint "notifiable_id"
    t.string "actor_type"
    t.bigint "actor_id"
    t.boolean "read", default: false, null: false
    t.datetime "read_at"
    t.boolean "email_sent", default: false
    t.datetime "email_sent_at"
    t.boolean "sms_sent", default: false
    t.datetime "sms_sent_at"
    t.string "action_url"
    t.string "action_text"
    t.jsonb "action_data", default: {}
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_notifications_on_category"
    t.index ["company_id", "created_at"], name: "index_notifications_on_company_id_and_created_at"
    t.index ["company_id", "notification_type"], name: "index_notifications_on_company_id_and_notification_type"
    t.index ["location_id"], name: "index_notifications_on_location_id"
    t.index ["notifiable_type", "notifiable_id"], name: "index_notifications_on_notifiable_type_and_notifiable_id"
    t.index ["priority"], name: "index_notifications_on_priority"
    t.index ["recipient_type", "recipient_id", "created_at"], name: "index_notifications_on_recipient_and_created"
    t.index ["recipient_type", "recipient_id", "read"], name: "index_notifications_on_recipient_and_read"
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

  create_table "part_categories", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.text "description"
    t.bigint "parent_id"
    t.boolean "active", default: true
    t.boolean "is_deleted", default: false
    t.datetime "deleted_at"
    t.jsonb "custom_fields", default: {}
    t.bigint "created_by_id"
    t.bigint "updated_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "active"], name: "index_part_categories_on_company_id_and_active"
    t.index ["company_id", "name"], name: "index_part_categories_on_company_id_and_name", unique: true, where: "(is_deleted = false)"
    t.index ["company_id"], name: "index_part_categories_on_company_id"
    t.index ["created_by_id"], name: "index_part_categories_on_created_by_id"
    t.index ["parent_id"], name: "index_part_categories_on_parent_id"
    t.index ["updated_by_id"], name: "index_part_categories_on_updated_by_id"
  end

  create_table "parts", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "sku", null: false
    t.string "name", null: false
    t.text "description"
    t.bigint "category_id"
    t.string "uom", default: "each"
    t.string "barcode"
    t.string "manufacturer_part_no"
    t.string "manufacturer_name"
    t.decimal "default_cost", precision: 10, scale: 2
    t.decimal "average_cost", precision: 10, scale: 2
    t.decimal "last_cost", precision: 10, scale: 2
    t.decimal "list_price", precision: 10, scale: 2
    t.decimal "sale_price", precision: 10, scale: 2
    t.boolean "taxable", default: true
    t.boolean "is_serialized", default: false
    t.boolean "is_lot_tracked", default: false
    t.string "inventory_method", default: "average_cost"
    t.decimal "weight_lbs", precision: 8, scale: 2
    t.decimal "length_inches", precision: 8, scale: 2
    t.decimal "width_inches", precision: 8, scale: 2
    t.decimal "height_inches", precision: 8, scale: 2
    t.string "qb_item_id"
    t.string "qb_income_account"
    t.string "qb_expense_account"
    t.string "qb_asset_account"
    t.boolean "active", default: true
    t.boolean "is_deleted", default: false
    t.datetime "deleted_at"
    t.jsonb "custom_fields", default: {}
    t.bigint "created_by_id"
    t.bigint "updated_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "manufacturer_id"
    t.index ["barcode"], name: "index_parts_on_barcode"
    t.index ["category_id"], name: "index_parts_on_category_id"
    t.index ["company_id", "active"], name: "index_parts_on_company_id_and_active"
    t.index ["company_id", "category_id"], name: "index_parts_on_company_id_and_category_id"
    t.index ["company_id", "name"], name: "index_parts_on_company_id_and_name", where: "(is_deleted = false)"
    t.index ["company_id", "sku"], name: "index_parts_on_company_id_and_sku", unique: true, where: "(is_deleted = false)"
    t.index ["company_id"], name: "index_parts_on_company_id"
    t.index ["created_by_id"], name: "index_parts_on_created_by_id"
    t.index ["manufacturer_id"], name: "index_parts_on_manufacturer_id"
    t.index ["manufacturer_part_no"], name: "index_parts_on_manufacturer_part_no"
    t.index ["qb_item_id"], name: "index_parts_on_qb_item_id"
    t.index ["updated_by_id"], name: "index_parts_on_updated_by_id"
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
    t.string "quickbooks_id"
    t.datetime "quickbooks_synced_at"
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
    t.index ["quickbooks_id"], name: "index_payments_on_quickbooks_id"
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

  create_table "purchase_order_lines", force: :cascade do |t|
    t.bigint "purchase_order_id", null: false
    t.bigint "part_id", null: false
    t.integer "line_number", null: false
    t.decimal "quantity_ordered", precision: 10, scale: 3, null: false
    t.decimal "quantity_received", precision: 10, scale: 3, default: "0.0", null: false
    t.decimal "unit_cost", precision: 10, scale: 2, null: false
    t.decimal "line_total", precision: 10, scale: 2, null: false
    t.text "description"
    t.text "notes"
    t.date "expected_date"
    t.string "manufacturer_part_no"
    t.jsonb "custom_fields", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "discount_percent", precision: 5, scale: 2, default: "0.0"
    t.index ["part_id"], name: "index_purchase_order_lines_on_part_id"
    t.index ["purchase_order_id", "line_number"], name: "idx_on_purchase_order_id_line_number_052fcfc9be", unique: true
    t.index ["purchase_order_id", "part_id"], name: "index_purchase_order_lines_on_purchase_order_id_and_part_id"
    t.index ["purchase_order_id"], name: "index_purchase_order_lines_on_purchase_order_id"
  end

  create_table "purchase_orders", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.bigint "supplier_id", null: false
    t.bigint "created_by_id"
    t.bigint "approved_by_id"
    t.string "po_number", null: false
    t.string "status", default: "draft", null: false
    t.date "order_date", null: false
    t.date "expected_delivery_date"
    t.date "delivery_date"
    t.decimal "subtotal", precision: 10, scale: 2, default: "0.0"
    t.decimal "tax_amount", precision: 10, scale: 2, default: "0.0"
    t.decimal "shipping_cost", precision: 10, scale: 2, default: "0.0"
    t.decimal "total_amount", precision: 10, scale: 2, default: "0.0"
    t.string "shipping_method"
    t.string "tracking_number"
    t.text "notes"
    t.text "terms"
    t.string "ship_to_name"
    t.string "ship_to_address1"
    t.string "ship_to_address2"
    t.string "ship_to_city"
    t.string "ship_to_state"
    t.string "ship_to_zip"
    t.string "ship_to_country", default: "US"
    t.datetime "sent_at"
    t.datetime "approved_at"
    t.datetime "cancelled_at"
    t.string "cancelled_reason"
    t.boolean "is_deleted", default: false, null: false
    t.datetime "deleted_at"
    t.jsonb "custom_fields", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_id"], name: "index_purchase_orders_on_approved_by_id"
    t.index ["company_id", "location_id"], name: "index_purchase_orders_on_company_id_and_location_id"
    t.index ["company_id", "po_number"], name: "index_purchase_orders_on_company_id_and_po_number", unique: true, where: "(is_deleted = false)"
    t.index ["company_id", "status"], name: "index_purchase_orders_on_company_id_and_status"
    t.index ["company_id", "supplier_id"], name: "index_purchase_orders_on_company_id_and_supplier_id"
    t.index ["company_id"], name: "index_purchase_orders_on_company_id"
    t.index ["created_by_id"], name: "index_purchase_orders_on_created_by_id"
    t.index ["expected_delivery_date"], name: "index_purchase_orders_on_expected_delivery_date"
    t.index ["is_deleted"], name: "index_purchase_orders_on_is_deleted"
    t.index ["location_id"], name: "index_purchase_orders_on_location_id"
    t.index ["order_date"], name: "index_purchase_orders_on_order_date"
    t.index ["status"], name: "index_purchase_orders_on_status"
    t.index ["supplier_id"], name: "index_purchase_orders_on_supplier_id"
  end

  create_table "quickbooks_field_mappings", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "entity_type", null: false
    t.string "renter_insight_field", null: false
    t.string "quickbooks_field", null: false
    t.string "mapping_type", default: "direct"
    t.text "transformation_logic"
    t.boolean "enabled", default: true
    t.integer "priority", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "entity_type"], name: "index_quickbooks_field_mappings_on_company_id_and_entity_type"
    t.index ["company_id"], name: "index_quickbooks_field_mappings_on_company_id"
    t.index ["location_id", "entity_type"], name: "index_quickbooks_field_mappings_on_location_id_and_entity_type"
    t.index ["location_id"], name: "index_quickbooks_field_mappings_on_location_id"
  end

  create_table "quickbooks_sync_logs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.bigint "quickbooks_sync_mapping_id"
    t.string "operation", null: false
    t.string "entity_type", null: false
    t.bigint "entity_id"
    t.string "sync_direction"
    t.string "status", default: "pending"
    t.text "error_message"
    t.jsonb "request_data"
    t.jsonb "response_data"
    t.float "duration_ms"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "created_at"], name: "index_quickbooks_sync_logs_on_company_id_and_created_at"
    t.index ["company_id"], name: "index_quickbooks_sync_logs_on_company_id"
    t.index ["entity_type"], name: "index_quickbooks_sync_logs_on_entity_type"
    t.index ["location_id", "created_at"], name: "index_quickbooks_sync_logs_on_location_id_and_created_at"
    t.index ["location_id"], name: "index_quickbooks_sync_logs_on_location_id"
    t.index ["quickbooks_sync_mapping_id"], name: "index_quickbooks_sync_logs_on_quickbooks_sync_mapping_id"
    t.index ["status"], name: "index_quickbooks_sync_logs_on_status"
  end

  create_table "quickbooks_sync_mappings", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "renter_insight_entity_type", null: false
    t.bigint "renter_insight_entity_id", null: false
    t.string "quickbooks_entity_type", null: false
    t.string "quickbooks_entity_id", null: false
    t.string "sync_direction", default: "bidirectional"
    t.datetime "last_synced_at"
    t.jsonb "last_sync_data"
    t.string "sync_status", default: "active"
    t.text "sync_error_message"
    t.integer "sync_error_count", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "quickbooks_entity_type", "quickbooks_entity_id"], name: "idx_qb_sync_qb_entity"
    t.index ["company_id", "renter_insight_entity_type", "renter_insight_entity_id"], name: "idx_qb_sync_ri_entity"
    t.index ["company_id"], name: "index_quickbooks_sync_mappings_on_company_id"
    t.index ["location_id"], name: "index_quickbooks_sync_mappings_on_location_id"
    t.index ["sync_status"], name: "index_quickbooks_sync_mappings_on_sync_status"
  end

  create_table "quickbooks_webhooks", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "realm_id", null: false
    t.string "event_name", null: false
    t.string "entity_name"
    t.string "entity_id"
    t.string "operation"
    t.jsonb "webhook_payload"
    t.string "status", default: "pending"
    t.text "processing_error"
    t.datetime "processed_at"
    t.integer "retry_count", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "status", "created_at"], name: "idx_on_company_id_status_created_at_0d2da1c8cd"
    t.index ["company_id"], name: "index_quickbooks_webhooks_on_company_id"
    t.index ["event_name"], name: "index_quickbooks_webhooks_on_event_name"
    t.index ["realm_id", "entity_id"], name: "index_quickbooks_webhooks_on_realm_id_and_entity_id"
  end

  create_table "quote_inventory_usages", force: :cascade do |t|
    t.bigint "quote_id", null: false
    t.bigint "part_id", null: false
    t.bigint "location_id"
    t.decimal "quantity", precision: 10, scale: 2, null: false
    t.decimal "unit_cost", precision: 10, scale: 2
    t.decimal "unit_price", precision: 10, scale: 2
    t.integer "item_index", comment: "Index in the quote.items JSONB array"
    t.boolean "used", default: false, null: false
    t.datetime "used_at"
    t.bigint "used_by_id"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["location_id"], name: "index_quote_inventory_usages_on_location_id"
    t.index ["part_id"], name: "index_quote_inventory_usages_on_part_id"
    t.index ["quote_id", "part_id"], name: "index_quote_inventory_usages_on_quote_id_and_part_id"
    t.index ["quote_id"], name: "index_quote_inventory_usages_on_quote_id"
    t.index ["used"], name: "index_quote_inventory_usages_on_used"
    t.index ["used_by_id"], name: "index_quote_inventory_usages_on_used_by_id"
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
    t.string "public_token"
    t.index ["account_id"], name: "index_quotes_on_account_id"
    t.index ["company_id", "location_id"], name: "index_quotes_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_quotes_on_company_id"
    t.index ["contact_id"], name: "index_quotes_on_contact_id"
    t.index ["created_at"], name: "index_quotes_on_created_at"
    t.index ["customer_id"], name: "index_quotes_on_customer_id"
    t.index ["is_deleted"], name: "index_quotes_on_is_deleted"
    t.index ["location_id"], name: "index_quotes_on_location_id"
    t.index ["public_token"], name: "index_quotes_on_public_token", unique: true
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

  create_table "reorder_rules", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "part_id", null: false
    t.bigint "location_id", null: false
    t.decimal "reorder_point", precision: 10, scale: 3, null: false
    t.decimal "reorder_quantity", precision: 10, scale: 3
    t.decimal "maximum_stock", precision: 10, scale: 3
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "active"], name: "index_reorder_rules_on_company_id_and_active"
    t.index ["company_id", "part_id", "location_id"], name: "index_reorder_rules_on_company_id_and_part_id_and_location_id", unique: true
    t.index ["company_id"], name: "index_reorder_rules_on_company_id"
    t.index ["location_id"], name: "index_reorder_rules_on_location_id"
    t.index ["part_id"], name: "index_reorder_rules_on_part_id"
  end

  create_table "resources", force: :cascade do |t|
    t.string "key", limit: 100, null: false
    t.string "name", null: false
    t.text "description"
    t.string "category", limit: 50
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "permission_ui_type", default: "standard_crud", null: false
    t.jsonb "permission_groups", default: {}, null: false
    t.index ["active"], name: "index_resources_on_active"
    t.index ["category"], name: "index_resources_on_category"
    t.index ["key"], name: "index_resources_on_key", unique: true
    t.index ["permission_ui_type"], name: "index_resources_on_permission_ui_type"
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
    t.string "department", comment: "Department category for role filtering (service, sales, finance, crm, operations)"
    t.index ["active"], name: "index_roles_on_active"
    t.index ["company_id", "tier", "key"], name: "index_roles_unique_per_company", unique: true
    t.index ["company_id"], name: "index_roles_on_company_id"
    t.index ["department"], name: "index_roles_on_department"
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
    t.boolean "is_warranty_suspected", default: false, null: false
    t.boolean "is_warranty_confirmed", default: false, null: false
    t.bigint "warranty_claim_id"
    t.jsonb "line_item_billing", default: []
    t.bigint "portal_user_id"
    t.boolean "is_portal_created", default: false
    t.text "portal_notes"
    t.text "home_info"
    t.boolean "portal_visible", default: true, null: false
    t.index ["account_id"], name: "index_service_tickets_on_account_id"
    t.index ["assigned_to"], name: "index_service_tickets_on_assigned_to"
    t.index ["company_id", "is_warranty_confirmed"], name: "index_service_tickets_on_company_id_and_is_warranty_confirmed"
    t.index ["company_id", "location_id"], name: "index_service_tickets_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_service_tickets_on_company_id"
    t.index ["contact_id"], name: "index_service_tickets_on_contact_id"
    t.index ["customer_type", "customer_id"], name: "index_service_tickets_on_customer_type_and_customer_id"
    t.index ["deleted_at"], name: "index_service_tickets_on_deleted_at"
    t.index ["is_portal_created"], name: "index_service_tickets_on_is_portal_created"
    t.index ["is_warranty_confirmed"], name: "index_service_tickets_on_is_warranty_confirmed"
    t.index ["is_warranty_suspected"], name: "index_service_tickets_on_is_warranty_suspected"
    t.index ["location_id"], name: "index_service_tickets_on_location_id"
    t.index ["portal_user_id"], name: "index_service_tickets_on_portal_user_id"
    t.index ["portal_visible"], name: "index_service_tickets_on_portal_visible"
    t.index ["priority"], name: "index_service_tickets_on_priority"
    t.index ["scheduled_date"], name: "index_service_tickets_on_scheduled_date"
    t.index ["status"], name: "index_service_tickets_on_status"
    t.index ["vehicle_id"], name: "index_service_tickets_on_vehicle_id"
    t.index ["warranty_claim_id"], name: "index_service_tickets_on_warranty_claim_id"
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

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.binary "payload", null: false
    t.datetime "created_at", null: false
    t.bigint "channel_hash", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
    t.index ["id"], name: "index_solid_cable_messages_on_id", unique: true
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

  create_table "stock_balances", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "part_id", null: false
    t.bigint "location_id", null: false
    t.bigint "bin_id"
    t.decimal "on_hand", precision: 10, scale: 3, default: "0.0", null: false
    t.decimal "reserved", precision: 10, scale: 3, default: "0.0", null: false
    t.decimal "available", precision: 10, scale: 3, default: "0.0", null: false
    t.string "serial_number"
    t.string "lot_number"
    t.date "lot_expiration_date"
    t.datetime "last_transaction_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bin_id"], name: "index_stock_balances_on_bin_id"
    t.index ["company_id", "location_id"], name: "index_stock_balances_on_company_id_and_location_id"
    t.index ["company_id", "part_id", "location_id", "bin_id", "serial_number", "lot_number"], name: "index_stock_balances_uniqueness", unique: true
    t.index ["company_id", "part_id"], name: "index_stock_balances_on_company_id_and_part_id"
    t.index ["company_id"], name: "index_stock_balances_on_company_id"
    t.index ["location_id"], name: "index_stock_balances_on_location_id"
    t.index ["lot_number"], name: "index_stock_balances_on_lot_number"
    t.index ["part_id", "location_id"], name: "index_stock_balances_on_part_id_and_location_id"
    t.index ["part_id"], name: "index_stock_balances_on_part_id"
    t.index ["serial_number"], name: "index_stock_balances_on_serial_number"
  end

  create_table "subscription_plan_modules", force: :cascade do |t|
    t.bigint "subscription_plan_id", null: false
    t.string "module_key", null: false
    t.boolean "is_enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["module_key", "is_enabled"], name: "index_subscription_plan_modules_on_module_key_and_is_enabled"
    t.index ["module_key"], name: "index_subscription_plan_modules_on_module_key"
    t.index ["subscription_plan_id", "module_key"], name: "idx_plan_modules_unique", unique: true
    t.index ["subscription_plan_id"], name: "index_subscription_plan_modules_on_subscription_plan_id"
  end

  create_table "subscription_plans", force: :cascade do |t|
    t.string "name", null: false
    t.string "display_name", null: false
    t.text "description"
    t.string "category", default: "professional", null: false
    t.string "zoho_plan_code"
    t.string "zoho_product_id"
    t.decimal "pricing_monthly", precision: 10, scale: 2, default: "0.0"
    t.decimal "pricing_annual", precision: 10, scale: 2, default: "0.0"
    t.string "currency", default: "USD"
    t.string "billing_model", default: "flat"
    t.integer "max_users", default: 10
    t.integer "max_storage_gb", default: 50
    t.integer "max_locations", default: 1
    t.integer "max_api_calls", default: 10000
    t.boolean "trial_enabled", default: true
    t.integer "trial_days", default: 14
    t.decimal "setup_fee", precision: 10, scale: 2, default: "0.0"
    t.string "discount_type"
    t.decimal "discount_value", precision: 10, scale: 2
    t.string "zoho_coupon_code"
    t.boolean "is_active", default: true
    t.boolean "is_popular", default: false
    t.integer "position", default: 0
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_subscription_plans_on_category"
    t.index ["is_active", "position"], name: "index_subscription_plans_on_is_active_and_position"
    t.index ["is_active"], name: "index_subscription_plans_on_is_active"
    t.index ["name"], name: "index_subscription_plans_on_name", unique: true
    t.index ["zoho_plan_code"], name: "index_subscription_plans_on_zoho_plan_code", unique: true, where: "(zoho_plan_code IS NOT NULL)"
  end

  create_table "supplier_parts", force: :cascade do |t|
    t.bigint "supplier_id", null: false
    t.bigint "part_id", null: false
    t.string "supplier_sku"
    t.decimal "last_cost", precision: 10, scale: 2
    t.integer "lead_time_days"
    t.decimal "minimum_order_quantity", precision: 10, scale: 3
    t.boolean "preferred", default: false
    t.jsonb "custom_fields", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["part_id", "preferred"], name: "index_supplier_parts_on_part_id_and_preferred"
    t.index ["part_id"], name: "index_supplier_parts_on_part_id"
    t.index ["supplier_id", "part_id"], name: "index_supplier_parts_on_supplier_id_and_part_id", unique: true
    t.index ["supplier_id"], name: "index_supplier_parts_on_supplier_id"
    t.index ["supplier_sku"], name: "index_supplier_parts_on_supplier_sku"
  end

  create_table "suppliers", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.string "code"
    t.string "contact_name"
    t.string "email"
    t.string "phone"
    t.string "website"
    t.string "address_line1"
    t.string "address_line2"
    t.string "city"
    t.string "state"
    t.string "zip_code"
    t.string "country", default: "US"
    t.string "tax_id"
    t.text "notes"
    t.string "payment_terms"
    t.integer "default_lead_time_days"
    t.string "qb_vendor_id"
    t.boolean "active", default: true
    t.boolean "is_deleted", default: false
    t.datetime "deleted_at"
    t.jsonb "custom_fields", default: {}
    t.bigint "created_by_id"
    t.bigint "updated_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "account_number"
    t.index ["company_id", "active"], name: "index_suppliers_on_company_id_and_active"
    t.index ["company_id", "code"], name: "index_suppliers_on_company_id_and_code", unique: true, where: "((code IS NOT NULL) AND (is_deleted = false))"
    t.index ["company_id", "name"], name: "index_suppliers_on_company_id_and_name", where: "(is_deleted = false)"
    t.index ["company_id"], name: "index_suppliers_on_company_id"
    t.index ["created_by_id"], name: "index_suppliers_on_created_by_id"
    t.index ["qb_vendor_id"], name: "index_suppliers_on_qb_vendor_id"
    t.index ["updated_by_id"], name: "index_suppliers_on_updated_by_id"
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

  create_table "tasks", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "taskable_type"
    t.bigint "taskable_id"
    t.string "title", null: false
    t.text "description"
    t.integer "status", default: 0, null: false
    t.integer "priority", default: 1, null: false
    t.string "task_module"
    t.bigint "assigned_to_id"
    t.datetime "due_date"
    t.datetime "completed_at"
    t.string "source_type"
    t.string "source_id"
    t.string "link"
    t.jsonb "tags", default: []
    t.jsonb "custom_fields", default: {}
    t.string "created_by"
    t.string "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["assigned_to_id"], name: "index_tasks_on_assigned_to_id"
    t.index ["company_id", "assigned_to_id"], name: "index_tasks_on_company_and_assigned_to"
    t.index ["company_id", "location_id"], name: "index_tasks_on_company_and_location"
    t.index ["company_id", "status"], name: "index_tasks_on_company_and_status"
    t.index ["company_id", "task_module"], name: "index_tasks_on_company_and_module"
    t.index ["company_id"], name: "index_tasks_on_company_id"
    t.index ["due_date"], name: "index_tasks_on_due_date"
    t.index ["location_id"], name: "index_tasks_on_location_id"
    t.index ["status", "due_date"], name: "index_tasks_on_status_and_due_date"
    t.index ["taskable_type", "taskable_id"], name: "index_tasks_on_taskable"
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

  create_table "tenant_module_overrides", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "module_key", null: false
    t.boolean "is_enabled", null: false
    t.string "override_reason"
    t.bigint "overridden_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "module_key"], name: "idx_tenant_module_override_unique", unique: true
    t.index ["company_id"], name: "index_tenant_module_overrides_on_company_id"
    t.index ["module_key", "is_enabled"], name: "index_tenant_module_overrides_on_module_key_and_is_enabled"
    t.index ["module_key"], name: "index_tenant_module_overrides_on_module_key"
    t.index ["overridden_by_id"], name: "index_tenant_module_overrides_on_overridden_by_id"
  end

  create_table "tenant_subscriptions", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "subscription_plan_id", null: false
    t.string "zoho_subscription_id"
    t.string "zoho_customer_id"
    t.string "status", default: "active", null: false
    t.string "billing_cycle", default: "monthly"
    t.datetime "current_period_start"
    t.datetime "current_period_end"
    t.datetime "trial_ends_at"
    t.datetime "cancelled_at"
    t.string "cancellation_reason"
    t.integer "current_users", default: 0
    t.integer "current_storage_gb", default: 0
    t.integer "current_locations", default: 0
    t.datetime "grace_period_ends_at"
    t.boolean "in_grace_period", default: false
    t.jsonb "metadata", default: {}
    t.jsonb "billing_history", default: []
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "status"], name: "idx_tenant_sub_company_status"
    t.index ["company_id"], name: "index_tenant_subscriptions_on_company_id"
    t.index ["current_period_end"], name: "index_tenant_subscriptions_on_current_period_end"
    t.index ["status"], name: "index_tenant_subscriptions_on_status"
    t.index ["subscription_plan_id"], name: "index_tenant_subscriptions_on_subscription_plan_id"
    t.index ["trial_ends_at"], name: "index_tenant_subscriptions_on_trial_ends_at"
    t.index ["zoho_subscription_id"], name: "index_tenant_subscriptions_on_zoho_subscription_id", unique: true, where: "(zoho_subscription_id IS NOT NULL)"
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

  create_table "user_view_preferences", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "company_id", null: false
    t.string "module", null: false
    t.bigint "active_view_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_view_id"], name: "index_user_view_preferences_on_active_view_id"
    t.index ["company_id"], name: "index_user_view_preferences_on_company_id"
    t.index ["user_id", "company_id", "module"], name: "idx_on_user_id_company_id_module_d4616a2f73", unique: true
    t.index ["user_id"], name: "index_user_view_preferences_on_user_id"
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
    t.jsonb "notification_settings", default: {"lead_reminders"=>{"enabled"=>true, "channels"=>{"sms"=>false, "bell"=>true, "email"=>false, "popup"=>true}}, "account_reminders"=>{"enabled"=>true, "channels"=>{"sms"=>false, "bell"=>true, "email"=>false, "popup"=>true}}, "contact_reminders"=>{"enabled"=>true, "channels"=>{"sms"=>false, "bell"=>true, "email"=>false, "popup"=>true}}, "activity_reminders"=>{"enabled"=>true, "channels"=>{"sms"=>false, "bell"=>true, "email"=>false, "popup"=>true}}}
    t.jsonb "custom_permissions", default: []
    t.index ["company_id"], name: "index_users_on_company_id"
    t.index ["custom_permissions"], name: "index_users_on_custom_permissions", using: :gin
    t.index ["deleted_at"], name: "index_users_on_deleted_at"
    t.index ["email", "invitation_id"], name: "index_users_on_email_and_invitation_id"
    t.index ["invitation_id"], name: "index_users_on_invitation_id"
    t.index ["invitation_token"], name: "index_users_on_invitation_token", unique: true
    t.index ["magic_link_token"], name: "index_users_on_magic_link_token", unique: true
    t.index ["mfa_enabled"], name: "index_users_on_mfa_enabled"
    t.index ["mfa_method"], name: "index_users_on_mfa_method"
    t.index ["mfa_sms_expires_at"], name: "index_users_on_mfa_sms_expires_at"
    t.index ["notification_settings"], name: "index_users_on_notification_settings", using: :gin
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
    t.string "rv_class", comment: "RV class type (Class A/B/C, Travel Trailer, Fifth Wheel, etc.)"
    t.string "engine_make", comment: "Engine manufacturer (Ford, Chevy, Cummins, etc.)"
    t.string "engine_type", comment: "Engine type (V8, V10, I6, etc.)"
    t.integer "sleeping_capacity", comment: "Number of people it sleeps"
    t.integer "num_air_conditioners", default: 0, comment: "Number of AC units"
    t.integer "slideouts", default: 0, comment: "Number of slide-outs"
    t.integer "awnings", default: 0, comment: "Number of awnings"
    t.decimal "fresh_water_capacity", precision: 8, scale: 2, comment: "Fresh water tank capacity in gallons"
    t.decimal "gray_water_capacity", precision: 8, scale: 2, comment: "Gray water tank capacity in gallons"
    t.decimal "black_water_capacity", precision: 8, scale: 2, comment: "Black water tank capacity in gallons"
    t.decimal "propane_capacity", precision: 8, scale: 2, comment: "Propane tank capacity in gallons"
    t.integer "dry_weight", comment: "Dry weight (UVW) in pounds"
    t.integer "gross_weight", comment: "Gross vehicle weight rating (GVWR) in pounds"
    t.integer "hitch_weight", comment: "Hitch/tongue weight in pounds"
    t.integer "cargo_capacity", comment: "Cargo carrying capacity in pounds"
    t.boolean "leveling_jacks", default: false, comment: "Has automatic leveling jacks"
    t.boolean "self_contained", default: false, comment: "Fully self-contained (bathroom, kitchen, etc.)"
    t.boolean "solar_panels", default: false, comment: "Has solar panel system"
    t.boolean "backup_camera", default: false, comment: "Has backup camera"
    t.boolean "satellite_tv", default: false, comment: "Has satellite TV capability"
    t.string "generator_make", comment: "Generator manufacturer"
    t.integer "generator_hours", comment: "Generator hours used"
    t.string "generator_fuel_type", comment: "Generator fuel type (Gas, Diesel, Propane)"
    t.string "video_url", comment: "YouTube or other video URL"
    t.string "virtual_tour_url", comment: "360° virtual tour URL"
    t.text "special_features", comment: "Additional special features or upgrades"
    t.string "overlay_text", comment: "Promotional overlay text for listings"
    t.string "quickbooks_id"
    t.datetime "quickbooks_synced_at"
    t.decimal "dealer_cost", precision: 10, scale: 2, comment: "Base invoice cost from manufacturer"
    t.decimal "freight_cost", precision: 10, scale: 2, comment: "Transportation/shipping cost to dealership"
    t.decimal "pdi_cost", precision: 10, scale: 2, comment: "Pre-delivery inspection and setup cost"
    t.decimal "total_cost", precision: 10, scale: 2, comment: "Total dealer cost (dealer_cost + freight + pdi)"
    t.decimal "holdback_amount", precision: 10, scale: 2, comment: "Manufacturer holdback/rebate amount"
    t.decimal "floor_plan_rate", precision: 5, scale: 3, comment: "Monthly floor plan interest rate (if financed)"
    t.decimal "target_gross", precision: 10, scale: 2, comment: "Target gross profit for this unit"
    t.decimal "minimum_price", precision: 10, scale: 2, comment: "Minimum acceptable selling price"
    t.index ["body_style"], name: "index_vehicles_on_body_style"
    t.index ["company_id", "inventory_id"], name: "index_vehicles_on_company_id_and_inventory_id", unique: true
    t.index ["company_id", "location_id"], name: "index_vehicles_on_company_id_and_location_id"
    t.index ["company_id", "serial_number"], name: "index_vehicles_on_company_id_and_serial_number", unique: true, where: "(serial_number IS NOT NULL)"
    t.index ["company_id", "vin"], name: "index_vehicles_on_company_id_and_vin", unique: true, where: "(vin IS NOT NULL)"
    t.index ["company_id"], name: "index_vehicles_on_company_id"
    t.index ["condition"], name: "index_vehicles_on_condition"
    t.index ["dealer_cost"], name: "index_vehicles_on_dealer_cost"
    t.index ["dwelling_type"], name: "index_vehicles_on_dwelling_type"
    t.index ["exterior_color"], name: "index_vehicles_on_exterior_color"
    t.index ["home_type"], name: "index_vehicles_on_home_type"
    t.index ["is_deleted"], name: "index_vehicles_on_is_deleted"
    t.index ["listing_type"], name: "index_vehicles_on_listing_type"
    t.index ["location_id"], name: "index_vehicles_on_location_id"
    t.index ["mileage", "year"], name: "index_vehicles_on_mileage_and_year"
    t.index ["quickbooks_id"], name: "index_vehicles_on_quickbooks_id"
    t.index ["rv_class"], name: "index_vehicles_on_rv_class"
    t.index ["rv_type"], name: "index_vehicles_on_rv_type"
    t.index ["sleeping_capacity"], name: "index_vehicles_on_sleeping_capacity"
    t.index ["slideouts"], name: "index_vehicles_on_slideouts"
    t.index ["status"], name: "index_vehicles_on_status"
    t.index ["total_cost"], name: "index_vehicles_on_total_cost"
    t.index ["year", "make", "model"], name: "index_vehicles_on_year_and_make_and_model"
  end

  create_table "warranty_claims", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.bigint "service_ticket_id", null: false
    t.bigint "manufacturer_id", null: false
    t.string "claim_number", null: false
    t.string "manufacturer_claim_number"
    t.decimal "estimated_amount", precision: 10, scale: 2
    t.decimal "approved_amount", precision: 10, scale: 2
    t.decimal "client_copay_amount", precision: 10, scale: 2, default: "0.0"
    t.jsonb "parts", default: []
    t.jsonb "labor", default: []
    t.string "status", default: "draft", null: false
    t.datetime "submitted_at"
    t.datetime "manufacturer_responded_at"
    t.datetime "approved_at"
    t.datetime "denied_at"
    t.datetime "closed_at"
    t.text "notes_internal"
    t.text "notes_to_manufacturer"
    t.text "manufacturer_response"
    t.text "denial_reason"
    t.string "public_token", null: false
    t.integer "views_count", default: 0
    t.string "submitted_by"
    t.string "approved_by"
    t.boolean "is_deleted", default: false, null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "owner_id"
    t.index ["company_id", "claim_number"], name: "index_warranty_claims_on_company_id_and_claim_number", unique: true
    t.index ["company_id", "is_deleted"], name: "index_warranty_claims_on_company_id_and_is_deleted"
    t.index ["company_id", "status"], name: "index_warranty_claims_on_company_id_and_status"
    t.index ["company_id"], name: "index_warranty_claims_on_company_id"
    t.index ["location_id"], name: "index_warranty_claims_on_location_id"
    t.index ["manufacturer_id"], name: "index_warranty_claims_on_manufacturer_id"
    t.index ["manufacturer_responded_at"], name: "index_warranty_claims_on_manufacturer_responded_at"
    t.index ["owner_id"], name: "index_warranty_claims_on_owner_id"
    t.index ["public_token"], name: "index_warranty_claims_on_public_token", unique: true
    t.index ["service_ticket_id"], name: "index_warranty_claims_on_service_ticket_id"
    t.index ["status"], name: "index_warranty_claims_on_status"
    t.index ["submitted_at"], name: "index_warranty_claims_on_submitted_at"
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
  add_foreign_key "bins", "locations"
  add_foreign_key "brochures", "companies"
  add_foreign_key "commission_audit_entries", "commissions"
  add_foreign_key "commission_audit_entries", "users"
  add_foreign_key "commission_components", "commission_plans", on_delete: :cascade
  add_foreign_key "commission_components", "companies"
  add_foreign_key "commission_components", "locations"
  add_foreign_key "commission_payment_line_items", "commission_components", on_delete: :nullify
  add_foreign_key "commission_payment_line_items", "commission_payments", on_delete: :cascade
  add_foreign_key "commission_payments", "commission_plans", on_delete: :nullify
  add_foreign_key "commission_payments", "companies"
  add_foreign_key "commission_payments", "deals"
  add_foreign_key "commission_payments", "locations"
  add_foreign_key "commission_payments", "users", column: "approved_by_user_id"
  add_foreign_key "commission_payments", "users", column: "paid_by_user_id"
  add_foreign_key "commission_payments", "users", column: "payee_user_id"
  add_foreign_key "commission_payments", "users", column: "reversed_by_user_id"
  add_foreign_key "commission_plans", "companies", on_delete: :cascade
  add_foreign_key "commission_plans", "locations", on_delete: :nullify
  add_foreign_key "commission_plans", "users", column: "assigned_user_id", on_delete: :nullify
  add_foreign_key "commission_rules", "companies"
  add_foreign_key "commissions", "commission_rules"
  add_foreign_key "commissions", "companies"
  add_foreign_key "commissions", "deals"
  add_foreign_key "commissions", "locations"
  add_foreign_key "commissions", "users"
  add_foreign_key "communication_events", "communications"
  add_foreign_key "communications", "communication_templates", column: "template_id"
  add_foreign_key "communications", "communication_threads"
  add_foreign_key "company_hidden_roles", "companies"
  add_foreign_key "company_hidden_roles", "roles"
  add_foreign_key "company_manufacturers", "companies"
  add_foreign_key "company_manufacturers", "manufacturers"
  add_foreign_key "contact_activities", "accounts"
  add_foreign_key "contact_activities", "contact_activities", column: "related_activity_id"
  add_foreign_key "contact_activities", "contacts"
  add_foreign_key "contact_activities", "users"
  add_foreign_key "contact_activities", "users", column: "assigned_to_id"
  add_foreign_key "contacts", "locations"
  add_foreign_key "custom_field_permissions", "custom_fields"
  add_foreign_key "custom_field_permissions", "roles"
  add_foreign_key "custom_fields", "companies"
  add_foreign_key "custom_fields", "users", column: "created_by_id"
  add_foreign_key "custom_fields", "users", column: "updated_by_id"
  add_foreign_key "custom_view_columns", "custom_views"
  add_foreign_key "custom_views", "companies"
  add_foreign_key "custom_views", "users", column: "created_by_id"
  add_foreign_key "dashboard_layouts", "companies"
  add_foreign_key "dashboard_layouts", "users"
  add_foreign_key "deal_activities", "deal_activities", column: "related_activity_id"
  add_foreign_key "deal_activities", "deals"
  add_foreign_key "deal_activities", "users"
  add_foreign_key "deal_activities", "users", column: "assigned_to_id"
  add_foreign_key "deal_products", "deals"
  add_foreign_key "deal_stage_histories", "deals"
  add_foreign_key "deal_stage_histories", "users", column: "changed_by_id"
  add_foreign_key "deals", "accounts"
  add_foreign_key "deals", "commission_plans"
  add_foreign_key "deals", "companies"
  add_foreign_key "deals", "contacts"
  add_foreign_key "deals", "locations"
  add_foreign_key "deals", "sources"
  add_foreign_key "deals", "users"
  add_foreign_key "deals", "users", column: "desk_manager_id"
  add_foreign_key "deals", "users", column: "finance_manager_id"
  add_foreign_key "deals", "users", column: "primary_salesperson_id"
  add_foreign_key "deals", "users", column: "sales_manager_id"
  add_foreign_key "deals", "users", column: "secondary_salesperson_id"
  add_foreign_key "intake_forms", "companies"
  add_foreign_key "intake_forms", "sources"
  add_foreign_key "intake_submissions", "leads"
  add_foreign_key "inventory_transactions", "bins"
  add_foreign_key "inventory_transactions", "companies"
  add_foreign_key "inventory_transactions", "inventory_transactions", column: "source_transaction_id"
  add_foreign_key "inventory_transactions", "locations"
  add_foreign_key "inventory_transactions", "parts"
  add_foreign_key "inventory_transactions", "purchase_order_lines"
  add_foreign_key "inventory_transactions", "users", column: "created_by_id"
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
  add_foreign_key "location_manufacturers", "locations"
  add_foreign_key "location_manufacturers", "manufacturers"
  add_foreign_key "locations", "companies"
  add_foreign_key "lot_map_history_entries", "lot_map_lots", column: "lot_id"
  add_foreign_key "lot_map_history_entries", "users"
  add_foreign_key "lot_map_history_entries", "vehicles", column: "inventory_id"
  add_foreign_key "lot_map_layouts", "companies"
  add_foreign_key "lot_map_lots", "lot_map_layouts", column: "layout_id"
  add_foreign_key "lot_map_lots", "vehicles", column: "assigned_inventory_id"
  add_foreign_key "manufacturer_ar_payments", "companies", on_delete: :cascade
  add_foreign_key "manufacturer_ar_payments", "manufacturer_ar_transactions", on_delete: :cascade
  add_foreign_key "manufacturer_ar_transactions", "companies", on_delete: :cascade
  add_foreign_key "manufacturer_ar_transactions", "locations", on_delete: :nullify
  add_foreign_key "manufacturer_ar_transactions", "manufacturers", on_delete: :restrict
  add_foreign_key "manufacturer_ar_transactions", "warranty_claims", on_delete: :restrict
  add_foreign_key "manufacturer_claim_views", "companies"
  add_foreign_key "manufacturer_claim_views", "warranty_claims"
  add_foreign_key "notes", "users"
  add_foreign_key "nurture_enrollments", "companies"
  add_foreign_key "nurture_enrollments", "leads"
  add_foreign_key "nurture_enrollments", "nurture_sequences"
  add_foreign_key "nurture_sequences", "companies"
  add_foreign_key "nurture_steps", "nurture_sequences"
  add_foreign_key "nurture_steps", "templates"
  add_foreign_key "part_categories", "companies"
  add_foreign_key "part_categories", "part_categories", column: "parent_id"
  add_foreign_key "part_categories", "users", column: "created_by_id"
  add_foreign_key "part_categories", "users", column: "updated_by_id"
  add_foreign_key "parts", "companies"
  add_foreign_key "parts", "manufacturers"
  add_foreign_key "parts", "part_categories", column: "category_id"
  add_foreign_key "parts", "users", column: "created_by_id"
  add_foreign_key "parts", "users", column: "updated_by_id"
  add_foreign_key "payment_methods", "companies"
  add_foreign_key "payment_methods", "locations"
  add_foreign_key "payments", "companies"
  add_foreign_key "payments", "loans"
  add_foreign_key "payments", "locations"
  add_foreign_key "payments", "payment_methods"
  add_foreign_key "purchase_order_lines", "parts"
  add_foreign_key "purchase_order_lines", "purchase_orders"
  add_foreign_key "purchase_orders", "companies"
  add_foreign_key "purchase_orders", "locations"
  add_foreign_key "purchase_orders", "suppliers"
  add_foreign_key "purchase_orders", "users", column: "approved_by_id"
  add_foreign_key "purchase_orders", "users", column: "created_by_id"
  add_foreign_key "quickbooks_field_mappings", "companies"
  add_foreign_key "quickbooks_field_mappings", "locations"
  add_foreign_key "quickbooks_sync_logs", "companies"
  add_foreign_key "quickbooks_sync_logs", "locations"
  add_foreign_key "quickbooks_sync_logs", "quickbooks_sync_mappings"
  add_foreign_key "quickbooks_sync_mappings", "companies"
  add_foreign_key "quickbooks_sync_mappings", "locations"
  add_foreign_key "quickbooks_webhooks", "companies"
  add_foreign_key "quote_inventory_usages", "locations"
  add_foreign_key "quote_inventory_usages", "parts"
  add_foreign_key "quote_inventory_usages", "quotes"
  add_foreign_key "quote_inventory_usages", "users", column: "used_by_id"
  add_foreign_key "quotes", "accounts"
  add_foreign_key "quotes", "contacts"
  add_foreign_key "quotes", "locations"
  add_foreign_key "reminders", "leads"
  add_foreign_key "reminders", "users"
  add_foreign_key "reorder_rules", "companies"
  add_foreign_key "reorder_rules", "locations"
  add_foreign_key "reorder_rules", "parts"
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
  add_foreign_key "service_tickets", "warranty_claims", on_delete: :nullify
  add_foreign_key "stock_balances", "bins"
  add_foreign_key "stock_balances", "companies"
  add_foreign_key "stock_balances", "locations"
  add_foreign_key "stock_balances", "parts"
  add_foreign_key "subscription_plan_modules", "subscription_plans"
  add_foreign_key "supplier_parts", "parts"
  add_foreign_key "supplier_parts", "suppliers"
  add_foreign_key "suppliers", "companies"
  add_foreign_key "suppliers", "users", column: "created_by_id"
  add_foreign_key "suppliers", "users", column: "updated_by_id"
  add_foreign_key "syndication_partners", "companies"
  add_foreign_key "tag_assignments", "tags"
  add_foreign_key "tasks", "companies"
  add_foreign_key "tasks", "locations"
  add_foreign_key "tasks", "users", column: "assigned_to_id"
  add_foreign_key "templates", "companies"
  add_foreign_key "tenant_module_overrides", "companies"
  add_foreign_key "tenant_module_overrides", "users", column: "overridden_by_id"
  add_foreign_key "tenant_subscriptions", "companies"
  add_foreign_key "tenant_subscriptions", "subscription_plans"
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
  add_foreign_key "user_view_preferences", "companies"
  add_foreign_key "user_view_preferences", "custom_views", column: "active_view_id"
  add_foreign_key "user_view_preferences", "users"
  add_foreign_key "users", "companies"
  add_foreign_key "users", "invitations"
  add_foreign_key "vehicles", "companies"
  add_foreign_key "vehicles", "locations"
  add_foreign_key "warranty_claims", "companies", on_delete: :cascade
  add_foreign_key "warranty_claims", "locations", on_delete: :nullify
  add_foreign_key "warranty_claims", "manufacturers", on_delete: :restrict
  add_foreign_key "warranty_claims", "service_tickets", on_delete: :restrict
  add_foreign_key "win_loss_reports", "deals"
  add_foreign_key "win_loss_reports", "users"
end
