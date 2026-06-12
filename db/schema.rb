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

ActiveRecord::Schema[8.0].define(version: 2026_06_12_130000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vector"

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

  create_table "account_links", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "linkable_type", null: false
    t.bigint "linkable_id", null: false
    t.string "link_purpose", null: false
    t.bigint "chart_of_account_id", null: false
    t.integer "priority", default: 0
    t.boolean "is_active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chart_of_account_id"], name: "index_account_links_on_chart_of_account_id"
    t.index ["company_id", "link_purpose"], name: "index_account_links_on_company_id_and_link_purpose"
    t.index ["company_id"], name: "index_account_links_on_company_id"
    t.index ["linkable_type", "linkable_id", "link_purpose"], name: "idx_account_links_polymorphic_purpose"
  end

  create_table "accounting_imports", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id", null: false
    t.string "source_type", null: false
    t.string "status", default: "pending"
    t.date "cutover_date"
    t.jsonb "import_config", default: {}
    t.jsonb "results", default: {}
    t.jsonb "errors_log", default: []
    t.integer "total_imported", default: 0
    t.integer "total_skipped", default: 0
    t.integer "total_errors", default: 0
    t.text "notes"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "source_type"], name: "index_accounting_imports_on_company_id_and_source_type"
    t.index ["company_id"], name: "index_accounting_imports_on_company_id"
    t.index ["status"], name: "index_accounting_imports_on_status"
    t.index ["user_id"], name: "index_accounting_imports_on_user_id"
  end

  create_table "accounting_settings", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.integer "fiscal_year_start_month", default: 1
    t.bigint "retained_earnings_account_id"
    t.bigint "default_ar_account_id"
    t.bigint "default_ap_account_id"
    t.bigint "default_sales_revenue_account_id"
    t.bigint "default_cogs_account_id"
    t.bigint "default_sales_tax_payable_account_id"
    t.bigint "default_bank_account_id"
    t.boolean "auto_post_invoices", default: false
    t.boolean "auto_post_payments", default: false
    t.boolean "auto_post_purchases", default: false
    t.boolean "lock_period_on_close", default: true
    t.integer "check_number_sequence", default: 1
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "default_parts_inventory_account_id"
    t.bigint "default_vehicle_inventory_account_id"
    t.boolean "auto_post_purchase_orders", default: true
    t.boolean "auto_post_parts_usage", default: true
    t.string "accounting_method", default: "accrual", null: false
    t.boolean "floor_plan_tracking_enabled", default: false, null: false
    t.decimal "default_floor_plan_rate", precision: 8, scale: 5
    t.string "default_floor_plan_lender"
    t.boolean "sales_tax_enabled", default: false, null: false
    t.decimal "default_state_tax_rate", precision: 8, scale: 5
    t.decimal "default_county_tax_rate", precision: 8, scale: 5
    t.decimal "default_city_tax_rate", precision: 8, scale: 5
    t.bigint "state_tax_account_id"
    t.bigint "county_tax_account_id"
    t.bigint "city_tax_account_id"
    t.jsonb "tax_rates_by_state", default: {}, null: false
    t.boolean "auto_post_deals", default: false, null: false
    t.index ["city_tax_account_id"], name: "index_accounting_settings_on_city_tax_account_id"
    t.index ["company_id"], name: "index_accounting_settings_on_company_id", unique: true
    t.index ["county_tax_account_id"], name: "index_accounting_settings_on_county_tax_account_id"
    t.index ["default_ap_account_id"], name: "index_accounting_settings_on_default_ap_account_id"
    t.index ["default_ar_account_id"], name: "index_accounting_settings_on_default_ar_account_id"
    t.index ["default_bank_account_id"], name: "index_accounting_settings_on_default_bank_account_id"
    t.index ["default_cogs_account_id"], name: "index_accounting_settings_on_default_cogs_account_id"
    t.index ["default_parts_inventory_account_id"], name: "idx_on_default_parts_inventory_account_id_67295920a0"
    t.index ["default_sales_revenue_account_id"], name: "index_accounting_settings_on_default_sales_revenue_account_id"
    t.index ["default_sales_tax_payable_account_id"], name: "idx_on_default_sales_tax_payable_account_id_6cda82c2b5"
    t.index ["default_vehicle_inventory_account_id"], name: "idx_on_default_vehicle_inventory_account_id_cb785f0d78"
    t.index ["retained_earnings_account_id"], name: "index_accounting_settings_on_retained_earnings_account_id"
    t.index ["state_tax_account_id"], name: "index_accounting_settings_on_state_tax_account_id"
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
    t.jsonb "custom_field_values", default: {}, null: false
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

  create_table "activity_logs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id"
    t.string "trackable_type"
    t.bigint "trackable_id"
    t.bigint "account_id"
    t.bigint "location_id"
    t.string "action", null: false
    t.string "module_name", null: false
    t.string "entity_type_label"
    t.string "description", null: false
    t.jsonb "changes_made", default: {}
    t.jsonb "metadata", default: {}
    t.string "ip_address"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["action"], name: "index_activity_logs_on_action"
    t.index ["company_id", "account_id", "created_at"], name: "idx_on_company_id_account_id_created_at_c0beedc755"
    t.index ["company_id", "created_at"], name: "index_activity_logs_on_company_id_and_created_at"
    t.index ["company_id", "location_id", "created_at"], name: "idx_on_company_id_location_id_created_at_2dcf7b4b92"
    t.index ["company_id", "module_name", "created_at"], name: "idx_on_company_id_module_name_created_at_290527c75b"
    t.index ["company_id", "user_id", "created_at"], name: "index_activity_logs_on_company_id_and_user_id_and_created_at"
    t.index ["trackable_type", "trackable_id"], name: "index_activity_logs_on_trackable_type_and_trackable_id"
  end

  create_table "ad_campaigns", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "external_campaign_id", null: false
    t.string "name"
    t.string "objective"
    t.string "status"
    t.decimal "daily_budget", precision: 12, scale: 2
    t.decimal "lifetime_budget", precision: 12, scale: 2
    t.decimal "spend", precision: 12, scale: 2, default: "0.0"
    t.integer "impressions", default: 0
    t.integer "clicks", default: 0
    t.integer "reach", default: 0
    t.integer "leads_count", default: 0
    t.integer "deals_count", default: 0
    t.decimal "revenue", precision: 12, scale: 2, default: "0.0"
    t.decimal "cost_per_lead", precision: 10, scale: 2, default: "0.0"
    t.decimal "cost_per_deal", precision: 10, scale: 2, default: "0.0"
    t.decimal "roi_percentage", precision: 10, scale: 2, default: "0.0"
    t.datetime "synced_at"
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "external_campaign_id"], name: "index_ad_campaigns_on_company_id_and_external_campaign_id", unique: true
    t.index ["company_id", "status"], name: "index_ad_campaigns_on_company_id_and_status"
  end

  create_table "agreement_attachments", force: :cascade do |t|
    t.bigint "agreement_id", null: false
    t.string "attachable_type"
    t.integer "attachable_id"
    t.integer "attached_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "filename"
    t.string "file_url"
    t.string "file_content_type"
    t.bigint "byte_size"
    t.index ["agreement_id", "attachable_type", "attachable_id"], name: "idx_agr_attachments_unique", unique: true
    t.index ["agreement_id"], name: "index_agreement_attachments_on_agreement_id"
    t.index ["attachable_type", "attachable_id"], name: "idx_agr_attachments_polymorphic"
    t.index ["attached_by_id"], name: "index_agreement_attachments_on_attached_by_id"
  end

  create_table "agreement_audit_logs", force: :cascade do |t|
    t.bigint "agreement_id", null: false
    t.bigint "agreement_signer_id"
    t.string "action", null: false
    t.string "ip_address"
    t.text "user_agent"
    t.string "geolocation"
    t.string "performed_by_type"
    t.integer "performed_by_id"
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agreement_id", "action"], name: "idx_agr_audit_agreement_action"
    t.index ["agreement_id", "created_at"], name: "idx_agr_audit_agreement_time"
    t.index ["agreement_id"], name: "index_agreement_audit_logs_on_agreement_id"
    t.index ["agreement_signer_id"], name: "index_agreement_audit_logs_on_agreement_signer_id"
    t.index ["performed_by_type", "performed_by_id"], name: "idx_agr_audit_performer"
  end

  create_table "agreement_categories", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.text "description"
    t.string "color", default: "#6B7280"
    t.boolean "is_system", default: false, null: false
    t.integer "position", default: 0, null: false
    t.boolean "is_deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "is_deleted"], name: "index_agreement_categories_on_company_id_and_is_deleted"
    t.index ["company_id", "name"], name: "idx_agreement_categories_unique_name", unique: true, where: "(is_deleted = false)"
    t.index ["company_id"], name: "index_agreement_categories_on_company_id"
  end

  create_table "agreement_reminders", force: :cascade do |t|
    t.bigint "agreement_id", null: false
    t.bigint "agreement_signer_id", null: false
    t.datetime "scheduled_at", null: false
    t.datetime "sent_at"
    t.string "reminder_type", default: "auto", null: false
    t.string "channel", default: "email", null: false
    t.string "status", default: "pending", null: false
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agreement_id", "agreement_signer_id"], name: "idx_agr_reminders_agr_signer"
    t.index ["agreement_id"], name: "index_agreement_reminders_on_agreement_id"
    t.index ["agreement_signer_id"], name: "index_agreement_reminders_on_agreement_signer_id"
    t.index ["scheduled_at", "sent_at"], name: "idx_agr_reminders_pending", where: "(sent_at IS NULL)"
  end

  create_table "agreement_signers", force: :cascade do |t|
    t.bigint "agreement_id", null: false
    t.string "role", default: "signer", null: false
    t.integer "signing_order", default: 1, null: false
    t.string "signable_type"
    t.integer "signable_id"
    t.string "name", null: false
    t.string "email", null: false
    t.string "phone"
    t.string "access_token", null: false
    t.string "status", default: "pending", null: false
    t.datetime "signed_at"
    t.datetime "viewed_at"
    t.datetime "declined_at"
    t.string "signature_url"
    t.string "signature_method"
    t.string "initials_url"
    t.string "initials_method"
    t.string "typed_signature"
    t.string "typed_initials"
    t.string "signature_font"
    t.string "ip_address"
    t.text "user_agent"
    t.text "decline_reason"
    t.string "signature_hash"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["access_token"], name: "index_agreement_signers_on_access_token", unique: true
    t.index ["agreement_id", "role"], name: "idx_agr_signers_agreement_role"
    t.index ["agreement_id"], name: "index_agreement_signers_on_agreement_id"
    t.index ["email"], name: "index_agreement_signers_on_email"
    t.index ["signable_type", "signable_id"], name: "idx_agr_signers_polymorphic"
    t.index ["status"], name: "index_agreement_signers_on_status"
  end

  create_table "agreement_templates", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.text "description"
    t.string "category"
    t.bigint "agreement_category_id"
    t.string "document_url"
    t.text "content"
    t.string "template_type", default: "upload", null: false
    t.jsonb "merge_fields", default: {}
    t.jsonb "field_placements", default: []
    t.jsonb "default_signers", default: []
    t.string "status", default: "draft", null: false
    t.integer "version", default: 1, null: false
    t.boolean "is_system_template", default: false, null: false
    t.bigint "location_id"
    t.integer "created_by_id"
    t.boolean "is_deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "merge_field_placements", default: []
    t.jsonb "document_urls", default: []
    t.string "state_code"
    t.string "form_type"
    t.string "form_number"
    t.boolean "is_platform_template", default: false, null: false
    t.jsonb "custom_field_definitions", default: [], null: false
    t.integer "page_count"
    t.string "template_group_id"
    t.boolean "is_master", default: false, null: false
    t.jsonb "cached_scan_results"
    t.datetime "scan_performed_at"
    t.string "example_document_url"
    t.index ["agreement_category_id"], name: "index_agreement_templates_on_agreement_category_id"
    t.index ["company_id", "category"], name: "idx_agr_templates_company_category"
    t.index ["company_id", "status", "is_deleted"], name: "idx_agr_templates_company_status"
    t.index ["company_id"], name: "index_agreement_templates_on_company_id"
    t.index ["created_by_id"], name: "index_agreement_templates_on_created_by_id"
    t.index ["form_number"], name: "idx_agr_templates_form_number"
    t.index ["is_platform_template", "state_code", "status"], name: "idx_platform_templates_state_lookup"
    t.index ["location_id"], name: "index_agreement_templates_on_location_id"
    t.index ["state_code"], name: "idx_agr_templates_state_code"
    t.index ["template_group_id", "is_master"], name: "idx_templates_group_master"
    t.index ["template_group_id", "state_code"], name: "idx_agr_templates_group_state", unique: true
    t.index ["template_group_id"], name: "idx_agr_templates_group"
  end

  create_table "agreements", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "agreement_template_id"
    t.string "title", null: false
    t.text "description"
    t.string "agreement_number", null: false
    t.string "category"
    t.string "status", default: "draft", null: false
    t.string "document_url"
    t.string "sealed_document_url"
    t.text "content"
    t.string "content_type", default: "upload", null: false
    t.jsonb "merge_field_values", default: {}
    t.jsonb "field_placements", default: []
    t.integer "prepared_by_id"
    t.datetime "expires_at"
    t.datetime "sent_at"
    t.datetime "completed_at"
    t.datetime "voided_at"
    t.datetime "declined_at"
    t.integer "voided_by_id"
    t.text "void_reason"
    t.integer "version", default: 1, null: false
    t.integer "parent_agreement_id"
    t.integer "reminder_frequency_days", default: 3
    t.datetime "last_reminder_sent_at"
    t.bigint "location_id"
    t.jsonb "metadata", default: {}
    t.boolean "is_deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "contact_id"
    t.bigint "account_id"
    t.bigint "deal_id"
    t.jsonb "merge_field_placements", default: []
    t.string "delivery_method", default: "email", null: false
    t.string "signing_order", default: "parallel", null: false
    t.text "message_to_signers"
    t.jsonb "document_urls", default: []
    t.jsonb "custom_field_values", default: {}, null: false
    t.jsonb "optional_equipment_snapshot", default: [], null: false
    t.jsonb "custom_field_definitions", default: []
    t.index ["account_id"], name: "index_agreements_on_account_id"
    t.index ["agreement_template_id"], name: "index_agreements_on_agreement_template_id"
    t.index ["company_id", "account_id"], name: "idx_agreements_company_account"
    t.index ["company_id", "agreement_number"], name: "idx_agreements_unique_number", unique: true
    t.index ["company_id", "category"], name: "idx_agreements_company_category"
    t.index ["company_id", "contact_id"], name: "idx_agreements_company_contact"
    t.index ["company_id", "deal_id"], name: "idx_agreements_company_deal"
    t.index ["company_id", "status", "is_deleted"], name: "idx_agreements_company_status"
    t.index ["company_id"], name: "index_agreements_on_company_id"
    t.index ["contact_id"], name: "index_agreements_on_contact_id"
    t.index ["deal_id"], name: "index_agreements_on_deal_id"
    t.index ["expires_at"], name: "index_agreements_on_expires_at"
    t.index ["location_id"], name: "index_agreements_on_location_id"
    t.index ["parent_agreement_id"], name: "index_agreements_on_parent_agreement_id"
    t.index ["prepared_by_id"], name: "index_agreements_on_prepared_by_id"
    t.index ["status", "expires_at"], name: "idx_agreements_expiry_check", where: "((status)::text = ANY (ARRAY[('sent'::character varying)::text, ('viewed'::character varying)::text, ('partially_signed'::character varying)::text]))"
    t.index ["voided_by_id"], name: "index_agreements_on_voided_by_id"
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

  create_table "ai_query_logs", force: :cascade do |t|
    t.bigint "company_id"
    t.bigint "user_id"
    t.bigint "location_id"
    t.string "feature"
    t.string "module_key"
    t.text "question"
    t.jsonb "generated_params", default: {}
    t.string "execution_status", default: "success"
    t.integer "result_count"
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.integer "cost_cents"
    t.integer "response_time_ms"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "action_name"
    t.string "failure_reason"
    t.string "entity_name_searched"
    t.string "entity_type_attempted"
    t.text "user_question"
    t.string "resolved_intent"
    t.integer "disambiguate_count"
    t.index ["action_name"], name: "index_ai_query_logs_on_action_name"
    t.index ["company_id", "feature", "created_at"], name: "index_ai_query_logs_on_company_id_and_feature_and_created_at"
    t.index ["company_id", "module_key"], name: "index_ai_query_logs_on_company_id_and_module_key"
    t.index ["failure_reason"], name: "index_ai_query_logs_on_failure_reason"
  end

  create_table "api_keys", force: :cascade do |t|
    t.bigint "company_id"
    t.string "name", null: false
    t.string "key", null: false
    t.string "secret_digest"
    t.jsonb "permissions", default: {}
    t.string "status", default: "active", null: false
    t.datetime "last_used_at"
    t.bigint "request_count", default: 0, null: false
    t.integer "rate_limit", default: 1000, null: false
    t.bigint "created_by_user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "status"], name: "index_api_keys_on_company_id_and_status"
    t.index ["company_id"], name: "index_api_keys_on_company_id"
    t.index ["created_by_user_id"], name: "index_api_keys_on_created_by_user_id"
    t.index ["key"], name: "index_api_keys_on_key", unique: true
    t.index ["status"], name: "index_api_keys_on_status"
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

  create_table "assignment_work_logs", force: :cascade do |t|
    t.bigint "contractor_assignment_id", null: false
    t.bigint "vendor_id"
    t.text "note"
    t.string "log_type", default: "note"
    t.jsonb "attachments", default: []
    t.datetime "logged_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "author_type", default: "contractor"
    t.string "author_name"
    t.index ["contractor_assignment_id"], name: "index_assignment_work_logs_on_contractor_assignment_id"
    t.index ["user_id"], name: "index_assignment_work_logs_on_user_id"
    t.index ["vendor_id"], name: "index_assignment_work_logs_on_vendor_id"
  end

  create_table "attachment_audiences", force: :cascade do |t|
    t.bigint "active_storage_attachment_id", null: false
    t.boolean "visible_to_customer", default: false, null: false
    t.boolean "visible_to_manufacturer", default: false, null: false
    t.bigint "tagged_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_storage_attachment_id"], name: "index_attachment_audiences_on_attachment", unique: true
  end

  create_table "audience_ai_generations", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id"
    t.text "prompt", null: false
    t.jsonb "context_snapshot", default: {}
    t.jsonb "generated_filter_tree", default: {}, null: false
    t.string "status", default: "generated", null: false
    t.bigint "parent_generation_id"
    t.string "model_version"
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.bigint "ai_query_log_id"
    t.string "source_type", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "audience_id"
    t.index ["ai_query_log_id"], name: "idx_audience_ai_gen_log"
    t.index ["audience_id"], name: "idx_audience_ai_gen_audience"
    t.index ["company_id"], name: "index_audience_ai_generations_on_company_id"
    t.index ["parent_generation_id"], name: "idx_audience_ai_gen_parent"
    t.index ["user_id"], name: "index_audience_ai_generations_on_user_id"
  end

  create_table "audiences", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.bigint "created_by_user_id"
    t.string "name", null: false
    t.text "description"
    t.string "source_type", null: false
    t.jsonb "filter_tree", default: {}, null: false
    t.jsonb "exclude_filter_tree", default: {}
    t.integer "estimated_count"
    t.datetime "estimated_at"
    t.bigint "generated_from_ai_generation_id"
    t.boolean "is_archived", default: false, null: false
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "manual_include_ids", default: []
    t.jsonb "manual_exclude_ids", default: []
    t.boolean "exclude_active_campaign_enrollees", default: false, null: false
    t.boolean "exclude_active_nurture_enrollees", default: false, null: false
    t.index ["company_id", "is_archived"], name: "index_audiences_on_company_id_and_is_archived"
    t.index ["company_id", "name"], name: "index_audiences_on_company_id_and_name"
    t.index ["company_id", "source_type"], name: "index_audiences_on_company_id_and_source_type"
    t.index ["company_id"], name: "index_audiences_on_company_id"
    t.index ["created_by_user_id"], name: "index_audiences_on_created_by_user_id"
    t.index ["generated_from_ai_generation_id"], name: "idx_audiences_on_ai_gen"
    t.index ["location_id"], name: "index_audiences_on_location_id"
  end

  create_table "bank_accounts", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "account_purpose", null: false
    t.string "account_type", null: false
    t.string "bank_name"
    t.string "routing_number"
    t.string "account_number"
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
    t.bigint "chart_of_account_id"
    t.string "stripe_customer_id"
    t.string "stripe_fc_account_id"
    t.string "stripe_fc_status"
    t.datetime "stripe_fc_last_synced_at"
    t.decimal "current_balance", precision: 15, scale: 2
    t.string "institution_name"
    t.string "account_mask"
    t.string "currency", default: "USD"
    t.decimal "opening_balance", precision: 15, scale: 2
    t.date "opened_on"
    t.boolean "check_printing_enabled", default: false
    t.integer "check_number", default: 0
    t.string "check_format"
    t.string "check_company_name"
    t.string "check_company_street"
    t.string "check_company_city"
    t.string "check_company_state"
    t.string "check_company_zip"
    t.string "check_signor_name"
    t.string "check_bank_name"
    t.string "stripe_last_cursor"
    t.text "stripe_error_message"
    t.string "check_company_phone"
    t.string "check_bank_city"
    t.string "check_bank_state"
    t.string "check_aba_fractional_number"
    t.string "check_signature_heading"
    t.index ["chart_of_account_id"], name: "index_bank_accounts_on_chart_of_account_id"
    t.index ["company_id", "location_id"], name: "index_bank_accounts_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_bank_accounts_on_company_id"
    t.index ["external_id"], name: "index_bank_accounts_on_external_id"
    t.index ["is_deleted"], name: "index_bank_accounts_on_is_deleted"
    t.index ["location_id", "account_purpose"], name: "index_bank_accounts_on_location_id_and_account_purpose"
    t.index ["location_id"], name: "index_bank_accounts_on_location_id"
    t.index ["stripe_fc_account_id"], name: "index_bank_accounts_on_stripe_fc_account_id", unique: true, where: "(stripe_fc_account_id IS NOT NULL)"
    t.index ["stripe_fc_status"], name: "index_bank_accounts_on_stripe_fc_status"
  end

  create_table "bank_reconciliation_items", force: :cascade do |t|
    t.bigint "bank_reconciliation_id", null: false
    t.bigint "journal_entry_line_id", null: false
    t.boolean "cleared", default: false
    t.date "cleared_date"
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bank_reconciliation_id", "cleared"], name: "idx_recon_items_cleared"
    t.index ["bank_reconciliation_id"], name: "index_bank_reconciliation_items_on_bank_reconciliation_id"
    t.index ["journal_entry_line_id"], name: "index_bank_reconciliation_items_on_journal_entry_line_id"
  end

  create_table "bank_reconciliations", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "bank_account_id", null: false
    t.date "statement_date", null: false
    t.decimal "statement_ending_balance", precision: 15, scale: 2, null: false
    t.decimal "beginning_balance", precision: 15, scale: 2, null: false
    t.decimal "cleared_deposits", precision: 15, scale: 2, default: "0.0"
    t.decimal "cleared_payments", precision: 15, scale: 2, default: "0.0"
    t.decimal "calculated_balance", precision: 15, scale: 2, default: "0.0"
    t.decimal "difference", precision: 15, scale: 2, default: "0.0"
    t.string "status", default: "in_progress"
    t.datetime "completed_at"
    t.bigint "completed_by_id"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bank_account_id", "statement_date"], name: "idx_on_bank_account_id_statement_date_e24fec856a"
    t.index ["bank_account_id"], name: "index_bank_reconciliations_on_bank_account_id"
    t.index ["company_id", "status"], name: "index_bank_reconciliations_on_company_id_and_status"
    t.index ["company_id"], name: "index_bank_reconciliations_on_company_id"
    t.index ["completed_by_id"], name: "index_bank_reconciliations_on_completed_by_id"
  end

  create_table "bank_rules", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.bigint "bank_account_id"
    t.string "match_type", null: false
    t.string "match_field", default: "description"
    t.string "match_value", null: false
    t.decimal "min_amount", precision: 15, scale: 2
    t.decimal "max_amount", precision: 15, scale: 2
    t.string "transaction_direction", default: "any"
    t.bigint "assign_account_id"
    t.bigint "assign_contact_id"
    t.string "assign_memo"
    t.boolean "auto_confirm", default: false
    t.integer "priority", default: 100
    t.integer "match_count", default: 0
    t.boolean "is_active", default: true
    t.datetime "last_matched_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "action_type", default: "categorize", null: false
    t.string "exclude_reason"
    t.index ["assign_account_id"], name: "index_bank_rules_on_assign_account_id"
    t.index ["assign_contact_id"], name: "index_bank_rules_on_assign_contact_id"
    t.index ["bank_account_id"], name: "index_bank_rules_on_bank_account_id"
    t.index ["company_id", "is_active"], name: "index_bank_rules_on_company_id_and_is_active"
    t.index ["company_id", "priority"], name: "index_bank_rules_on_company_id_and_priority"
    t.index ["company_id"], name: "index_bank_rules_on_company_id"
  end

  create_table "bank_transactions", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "bank_account_id", null: false
    t.date "transaction_date", null: false
    t.date "post_date"
    t.text "description"
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.string "reference_number"
    t.string "transaction_type"
    t.string "fitid"
    t.string "stripe_txn_id"
    t.string "status", default: "unmatched"
    t.bigint "matched_journal_entry_id"
    t.datetime "matched_at"
    t.string "matched_by"
    t.bigint "category_account_id"
    t.bigint "rule_id"
    t.text "excluded_reason"
    t.text "memo"
    t.bigint "contact_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bank_account_id", "fitid"], name: "idx_bank_txn_fitid_unique", unique: true, where: "(fitid IS NOT NULL)"
    t.index ["bank_account_id", "status"], name: "index_bank_transactions_on_bank_account_id_and_status"
    t.index ["bank_account_id"], name: "index_bank_transactions_on_bank_account_id"
    t.index ["category_account_id"], name: "index_bank_transactions_on_category_account_id"
    t.index ["company_id"], name: "index_bank_transactions_on_company_id"
    t.index ["contact_id"], name: "index_bank_transactions_on_contact_id"
    t.index ["matched_journal_entry_id"], name: "index_bank_transactions_on_matched_journal_entry_id"
    t.index ["rule_id"], name: "index_bank_transactions_on_rule_id"
    t.index ["stripe_txn_id"], name: "index_bank_transactions_on_stripe_txn_id", unique: true, where: "(stripe_txn_id IS NOT NULL)"
    t.index ["transaction_date"], name: "index_bank_transactions_on_transaction_date"
  end

  create_table "bill_line_items", force: :cascade do |t|
    t.bigint "bill_id", null: false
    t.bigint "chart_of_account_id", null: false
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.string "description"
    t.bigint "location_id"
    t.string "department"
    t.integer "position", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bill_id"], name: "index_bill_line_items_on_bill_id"
    t.index ["chart_of_account_id"], name: "index_bill_line_items_on_chart_of_account_id"
    t.index ["location_id"], name: "index_bill_line_items_on_location_id"
  end

  create_table "bill_payments", force: :cascade do |t|
    t.bigint "bill_id", null: false
    t.bigint "company_id", null: false
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.date "payment_date", null: false
    t.string "payment_method"
    t.string "check_number"
    t.bigint "bank_account_id"
    t.bigint "chart_of_account_id"
    t.bigint "journal_entry_id"
    t.text "memo"
    t.bigint "created_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "voided", default: false, null: false
    t.datetime "voided_at"
    t.index ["bank_account_id"], name: "index_bill_payments_on_bank_account_id"
    t.index ["bill_id", "voided"], name: "index_bill_payments_on_bill_id_and_voided"
    t.index ["bill_id"], name: "index_bill_payments_on_bill_id"
    t.index ["chart_of_account_id"], name: "index_bill_payments_on_chart_of_account_id"
    t.index ["company_id"], name: "index_bill_payments_on_company_id"
    t.index ["created_by_id"], name: "index_bill_payments_on_created_by_id"
    t.index ["journal_entry_id"], name: "index_bill_payments_on_journal_entry_id"
  end

  create_table "bills", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "vendor_id"
    t.bigint "contact_id"
    t.bigint "location_id"
    t.string "bill_number"
    t.string "vendor_name"
    t.date "bill_date", null: false
    t.date "due_date"
    t.string "status", default: "draft", null: false
    t.decimal "subtotal", precision: 12, scale: 2, default: "0.0"
    t.decimal "tax_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "total_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "amount_paid", precision: 12, scale: 2, default: "0.0"
    t.decimal "balance_due", precision: 12, scale: 2, default: "0.0"
    t.string "payment_terms"
    t.text "memo"
    t.text "notes"
    t.string "reference_number"
    t.jsonb "attachments", default: []
    t.bigint "ap_account_id"
    t.bigint "journal_entry_id"
    t.bigint "payment_journal_entry_id"
    t.bigint "created_by_id"
    t.boolean "is_deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ap_account_id"], name: "index_bills_on_ap_account_id"
    t.index ["company_id", "bill_number"], name: "index_bills_on_company_id_and_bill_number", unique: true, where: "(bill_number IS NOT NULL)"
    t.index ["company_id", "due_date"], name: "index_bills_on_company_id_and_due_date"
    t.index ["company_id", "status"], name: "index_bills_on_company_id_and_status"
    t.index ["company_id"], name: "index_bills_on_company_id"
    t.index ["contact_id"], name: "index_bills_on_contact_id"
    t.index ["created_by_id"], name: "index_bills_on_created_by_id"
    t.index ["journal_entry_id"], name: "index_bills_on_journal_entry_id"
    t.index ["location_id"], name: "index_bills_on_location_id"
    t.index ["payment_journal_entry_id"], name: "index_bills_on_payment_journal_entry_id"
    t.index ["vendor_id"], name: "index_bills_on_vendor_id"
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

  create_table "blog_categories", force: :cascade do |t|
    t.bigint "website_id", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.text "description"
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "order", default: 0
    t.datetime "deleted_at"
    t.string "seo_title"
    t.text "seo_description"
    t.index ["website_id", "slug"], name: "index_blog_categories_on_website_id_and_slug", unique: true
    t.index ["website_id"], name: "index_blog_categories_on_website_id"
  end

  create_table "blog_posts", force: :cascade do |t|
    t.bigint "website_id", null: false
    t.bigint "author_id", null: false
    t.string "title", null: false
    t.string "slug", null: false
    t.text "excerpt"
    t.text "content"
    t.string "featured_image_url"
    t.integer "status", default: 0, null: false
    t.datetime "published_at"
    t.datetime "scheduled_at"
    t.string "seo_title"
    t.text "seo_description"
    t.string "og_image_url"
    t.integer "view_count", default: 0
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "featured_image_alt"
    t.string "robots"
    t.datetime "deleted_at"
    t.index ["author_id"], name: "index_blog_posts_on_author_id"
    t.index ["published_at"], name: "index_blog_posts_on_published_at"
    t.index ["status"], name: "index_blog_posts_on_status"
    t.index ["website_id", "slug"], name: "index_blog_posts_on_website_id_and_slug", unique: true
    t.index ["website_id"], name: "index_blog_posts_on_website_id"
  end

  create_table "blog_posts_categories", id: false, force: :cascade do |t|
    t.bigint "blog_post_id", null: false
    t.bigint "blog_category_id", null: false
    t.index ["blog_category_id"], name: "index_blog_posts_categories_on_blog_category_id"
    t.index ["blog_post_id", "blog_category_id"], name: "index_blog_posts_categories_on_post_and_category", unique: true
    t.index ["blog_post_id"], name: "index_blog_posts_categories_on_blog_post_id"
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

  create_table "budget_lines", force: :cascade do |t|
    t.bigint "budget_id", null: false
    t.bigint "chart_of_account_id", null: false
    t.decimal "month_1", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "month_2", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "month_3", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "month_4", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "month_5", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "month_6", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "month_7", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "month_8", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "month_9", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "month_10", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "month_11", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "month_12", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "annual_total", precision: 15, scale: 2, default: "0.0", null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_id", "chart_of_account_id"], name: "index_budget_lines_on_budget_and_account", unique: true
    t.index ["budget_id"], name: "index_budget_lines_on_budget_id"
    t.index ["chart_of_account_id"], name: "index_budget_lines_on_chart_of_account_id"
  end

  create_table "budgets", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.integer "fiscal_year", null: false
    t.string "name", null: false
    t.text "description"
    t.string "budget_type", default: "annual", null: false
    t.string "status", default: "draft", null: false
    t.string "consolidation_type", default: "standalone", null: false
    t.bigint "created_by_id"
    t.bigint "approved_by_id"
    t.datetime "approved_at"
    t.datetime "locked_at"
    t.bigint "locked_by_id"
    t.text "notes"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_id"], name: "index_budgets_on_approved_by_id"
    t.index ["company_id", "consolidation_type"], name: "index_budgets_on_company_id_and_consolidation_type"
    t.index ["company_id", "fiscal_year", "location_id", "name"], name: "index_budgets_on_company_year_location_name", unique: true
    t.index ["company_id", "fiscal_year"], name: "index_budgets_on_company_id_and_fiscal_year"
    t.index ["company_id", "location_id"], name: "index_budgets_on_company_id_and_location_id"
    t.index ["company_id", "status"], name: "index_budgets_on_company_id_and_status"
    t.index ["company_id"], name: "index_budgets_on_company_id"
    t.index ["created_by_id"], name: "index_budgets_on_created_by_id"
    t.index ["location_id"], name: "index_budgets_on_location_id"
    t.index ["locked_by_id"], name: "index_budgets_on_locked_by_id"
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

  create_table "campaign_ai_generations", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id", null: false
    t.bigint "campaign_id"
    t.text "prompt", null: false
    t.jsonb "context_snapshot", default: {}, null: false
    t.bigint "template_id_used"
    t.jsonb "generated_plan", default: {}, null: false
    t.string "status", default: "generated", null: false
    t.bigint "parent_generation_id"
    t.string "model_version"
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.bigint "ai_query_log_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["campaign_id"], name: "index_campaign_ai_generations_on_campaign_id"
    t.index ["company_id", "created_at"], name: "index_campaign_ai_generations_on_company_id_and_created_at"
    t.index ["user_id"], name: "index_campaign_ai_generations_on_user_id"
  end

  create_table "campaign_audiences", force: :cascade do |t|
    t.bigint "campaign_id", null: false
    t.string "source_type", null: false
    t.jsonb "filter_tree", default: {}, null: false
    t.jsonb "exclude_filter_tree", default: {}, null: false
    t.integer "estimated_count", default: 0, null: false
    t.datetime "estimated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "saved_audience_id"
    t.jsonb "manual_exclude_ids", default: []
    t.boolean "exclude_active_campaign_enrollees", default: false, null: false
    t.boolean "exclude_active_nurture_enrollees", default: false, null: false
    t.index ["campaign_id"], name: "index_campaign_audiences_on_campaign_id", unique: true
    t.index ["saved_audience_id"], name: "idx_campaign_audiences_saved_audience"
  end

  create_table "campaign_enrollments", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "campaign_id", null: false
    t.string "recipient_type", null: false
    t.bigint "recipient_id", null: false
    t.string "email_address_snapshot"
    t.string "status", default: "pending", null: false
    t.integer "current_step_index", default: 0, null: false
    t.datetime "next_send_at"
    t.datetime "last_sent_at"
    t.datetime "goal_met_at"
    t.string "goal_met_reason"
    t.datetime "unsubscribed_at"
    t.datetime "bounced_at"
    t.datetime "complained_at"
    t.string "failure_reason"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "sms_phone_snapshot"
    t.index ["campaign_id", "recipient_type", "recipient_id"], name: "idx_campaign_enrollments_unique", unique: true
    t.index ["campaign_id", "status", "next_send_at"], name: "idx_campaign_enrollments_due"
    t.index ["company_id"], name: "index_campaign_enrollments_on_company_id"
    t.index ["recipient_type", "recipient_id"], name: "index_campaign_enrollments_on_recipient_type_and_recipient_id"
  end

  create_table "campaign_events", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "campaign_id", null: false
    t.bigint "campaign_enrollment_id"
    t.bigint "campaign_send_id"
    t.string "event_type", null: false
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["campaign_id", "event_type", "occurred_at"], name: "idx_on_campaign_id_event_type_occurred_at_fb61660f49"
    t.index ["company_id"], name: "index_campaign_events_on_company_id"
  end

  create_table "campaign_link_tokens", force: :cascade do |t|
    t.bigint "campaign_id", null: false
    t.bigint "campaign_send_id", null: false
    t.string "token", null: false
    t.text "target_url", null: false
    t.integer "click_count", default: 0, null: false
    t.datetime "first_clicked_at"
    t.datetime "last_clicked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["campaign_send_id"], name: "index_campaign_link_tokens_on_campaign_send_id"
    t.index ["token"], name: "index_campaign_link_tokens_on_token", unique: true
  end

  create_table "campaign_sends", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "campaign_id", null: false
    t.bigint "campaign_step_id", null: false
    t.bigint "campaign_enrollment_id", null: false
    t.bigint "communication_id"
    t.datetime "sent_at"
    t.datetime "delivered_at"
    t.datetime "opened_at"
    t.integer "open_count", default: 0, null: false
    t.datetime "clicked_at"
    t.integer "click_count", default: 0, null: false
    t.datetime "replied_at"
    t.datetime "bounced_at"
    t.string "bounce_type"
    t.datetime "unsubscribed_at"
    t.datetime "goal_met_at"
    t.jsonb "inventory_vehicle_ids", default: [], null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["campaign_enrollment_id"], name: "index_campaign_sends_on_campaign_enrollment_id"
    t.index ["campaign_id", "sent_at"], name: "index_campaign_sends_on_campaign_id_and_sent_at"
    t.index ["communication_id"], name: "index_campaign_sends_on_communication_id"
    t.index ["company_id"], name: "index_campaign_sends_on_company_id"
  end

  create_table "campaign_steps", force: :cascade do |t|
    t.bigint "campaign_id", null: false
    t.integer "position", default: 0, null: false
    t.integer "wait_days", default: 0, null: false
    t.integer "wait_hours", default: 0, null: false
    t.string "subject"
    t.string "preheader"
    t.jsonb "body_blocks", default: [], null: false
    t.jsonb "inventory_block_config"
    t.boolean "is_active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "channel", default: "email", null: false
    t.text "sms_body"
    t.string "media_url"
    t.jsonb "attachments", default: []
    t.index ["campaign_id", "position"], name: "index_campaign_steps_on_campaign_id_and_position"
  end

  create_table "campaign_suppressions", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "email_address"
    t.string "reason", null: false
    t.bigint "source_campaign_id"
    t.datetime "suppressed_at", null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "phone_number"
    t.index ["company_id", "email_address"], name: "idx_campaign_suppressions_email_unique", unique: true, where: "(email_address IS NOT NULL)"
    t.index ["company_id", "phone_number"], name: "idx_campaign_suppressions_phone_unique", unique: true, where: "(phone_number IS NOT NULL)"
  end

  create_table "campaign_templates", force: :cascade do |t|
    t.bigint "company_id"
    t.string "slug", null: false
    t.string "name", null: false
    t.text "description"
    t.string "category", null: false
    t.string "vertical", null: false
    t.jsonb "audience_hint", default: {}, null: false
    t.jsonb "steps_template", default: [], null: false
    t.jsonb "goal_config_template", default: {}, null: false
    t.jsonb "send_window_template", default: {}, null: false
    t.boolean "is_seeded", default: false, null: false
    t.boolean "is_active", default: true, null: false
    t.bigint "created_by_user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "channel", default: "email", null: false
    t.index ["category"], name: "index_campaign_templates_on_category"
    t.index ["company_id", "slug"], name: "index_campaign_templates_on_company_id_and_slug", unique: true
    t.index ["vertical"], name: "index_campaign_templates_on_vertical"
  end

  create_table "campaigns", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.bigint "created_by_user_id", null: false
    t.string "name", null: false
    t.text "description"
    t.string "status", default: "draft", null: false
    t.string "campaign_type", null: false
    t.string "audience_mode", default: "static", null: false
    t.datetime "audience_snapshot_at"
    t.string "from_identity_type", null: false
    t.bigint "from_identity_id", null: false
    t.string "from_display_name"
    t.string "reply_to_address"
    t.string "subject_default"
    t.jsonb "goal_config", default: {}, null: false
    t.jsonb "reply_handling", default: {}, null: false
    t.jsonb "send_window", default: {}, null: false
    t.integer "throttle_per_day", default: 500, null: false
    t.string "utm_source"
    t.string "utm_medium"
    t.string "utm_campaign"
    t.datetime "scheduled_at"
    t.string "recurrence_cron"
    t.jsonb "trigger_config", default: {}, null: false
    t.datetime "started_at"
    t.datetime "completed_at"
    t.jsonb "stats_cache", default: {}, null: false
    t.boolean "is_deleted", default: false, null: false
    t.bigint "seeded_from_template_id"
    t.bigint "generated_from_ai_generation_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "channel", default: "email", null: false
    t.index ["campaign_type", "status"], name: "index_campaigns_on_campaign_type_and_status"
    t.index ["company_id", "channel"], name: "index_campaigns_on_company_id_and_channel"
    t.index ["company_id", "status"], name: "index_campaigns_on_company_id_and_status"
    t.index ["from_identity_type"], name: "index_campaigns_on_from_identity_type"
  end

  create_table "cash_receipt_applications", force: :cascade do |t|
    t.bigint "cash_receipt_id", null: false
    t.bigint "invoice_id", null: false
    t.decimal "amount_applied", precision: 12, scale: 2, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cash_receipt_id", "invoice_id"], name: "idx_cra_unique_receipt_invoice", unique: true
    t.index ["cash_receipt_id"], name: "index_cash_receipt_applications_on_cash_receipt_id"
    t.index ["invoice_id"], name: "index_cash_receipt_applications_on_invoice_id"
  end

  create_table "cash_receipts", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "account_id"
    t.bigint "contact_id"
    t.bigint "bank_account_id"
    t.bigint "journal_entry_id"
    t.bigint "location_id"
    t.bigint "created_by_id"
    t.string "receipt_number"
    t.date "receipt_date", null: false
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.decimal "amount_applied", precision: 12, scale: 2, default: "0.0"
    t.decimal "amount_unapplied", precision: 12, scale: 2, default: "0.0"
    t.string "payment_method"
    t.string "reference_number"
    t.text "memo"
    t.string "customer_name"
    t.string "status", default: "posted"
    t.datetime "voided_at"
    t.boolean "is_deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_cash_receipts_on_account_id"
    t.index ["bank_account_id"], name: "index_cash_receipts_on_bank_account_id"
    t.index ["company_id", "receipt_number"], name: "index_cash_receipts_on_company_id_and_receipt_number", unique: true, where: "(receipt_number IS NOT NULL)"
    t.index ["company_id", "status"], name: "index_cash_receipts_on_company_id_and_status"
    t.index ["company_id"], name: "index_cash_receipts_on_company_id"
    t.index ["contact_id"], name: "index_cash_receipts_on_contact_id"
    t.index ["created_by_id"], name: "index_cash_receipts_on_created_by_id"
    t.index ["journal_entry_id"], name: "index_cash_receipts_on_journal_entry_id"
    t.index ["location_id"], name: "index_cash_receipts_on_location_id"
    t.index ["receipt_date"], name: "index_cash_receipts_on_receipt_date"
  end

  create_table "champion_ims_retailers", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "retailer_navision_id", null: false
    t.string "retailer_name"
    t.string "retailer_city"
    t.string "retailer_state"
    t.boolean "active", default: true, null: false
    t.string "sync_frequency", default: "weekly", null: false
    t.datetime "last_sync_at"
    t.string "last_sync_status", default: "pending", null: false
    t.text "last_sync_error"
    t.jsonb "last_sync_stats", default: {}, null: false
    t.datetime "next_scheduled_sync_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "apply_to_all_locations", default: false, null: false, comment: "When true, synced vehicles are company-wide (location_id=nil) regardless of retailer.location_id"
    t.text "custom_retailer_sentence"
    t.index ["active"], name: "index_champion_ims_retailers_on_active"
    t.index ["company_id", "retailer_navision_id"], name: "idx_champion_ims_retailers_on_company_and_navision", unique: true
    t.index ["company_id"], name: "index_champion_ims_retailers_on_company_id"
    t.index ["last_sync_status"], name: "index_champion_ims_retailers_on_last_sync_status"
    t.index ["location_id"], name: "index_champion_ims_retailers_on_location_id"
    t.index ["next_scheduled_sync_at"], name: "index_champion_ims_retailers_on_next_scheduled_sync_at"
  end

  create_table "champion_ims_sync_events", force: :cascade do |t|
    t.bigint "champion_ims_sync_run_id", null: false
    t.bigint "vehicle_id"
    t.string "champion_model_id"
    t.string "event_type", null: false
    t.string "display_name"
    t.string "inventory_id"
    t.jsonb "field_changes", default: {}, null: false
    t.text "reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["champion_ims_sync_run_id"], name: "idx_cims_events_on_run"
    t.index ["champion_model_id"], name: "index_champion_ims_sync_events_on_champion_model_id"
    t.index ["event_type"], name: "index_champion_ims_sync_events_on_event_type"
    t.index ["vehicle_id", "created_at"], name: "idx_cims_events_on_vehicle_and_created_at", order: { created_at: :desc }
    t.index ["vehicle_id"], name: "idx_cims_events_on_vehicle"
  end

  create_table "champion_ims_sync_runs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "champion_ims_retailer_id", null: false
    t.string "status", default: "running", null: false
    t.datetime "started_at", null: false
    t.datetime "finished_at"
    t.integer "duration_ms"
    t.integer "catalog_added", default: 0, null: false
    t.integer "catalog_updated", default: 0, null: false
    t.integer "catalog_unchanged", default: 0, null: false
    t.integer "catalog_tombstoned", default: 0, null: false
    t.integer "catalog_protected", default: 0, null: false
    t.integer "vehicles_skipped", default: 0, null: false
    t.integer "total", default: 0, null: false
    t.string "trigger", default: "manual", null: false
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["champion_ims_retailer_id", "started_at"], name: "idx_cims_runs_on_retailer_and_started_at", order: { started_at: :desc }
    t.index ["champion_ims_retailer_id"], name: "idx_cims_runs_on_retailer"
    t.index ["company_id"], name: "index_champion_ims_sync_runs_on_company_id"
  end

  create_table "champion_lead_feed_configs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "api_token", null: false
    t.string "environment", default: "production", null: false
    t.string "champion_account_number"
    t.string "retailer_name"
    t.boolean "active", default: true, null: false
    t.datetime "last_synced_at"
    t.datetime "last_sync_error_at"
    t.text "last_sync_error"
    t.integer "total_leads_synced", default: 0, null: false
    t.integer "sync_interval_minutes", default: 15, null: false
    t.jsonb "last_sync_stats", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "default_lead_owner_id"
    t.index ["active"], name: "index_champion_lead_feed_configs_on_active"
    t.index ["company_id", "location_id"], name: "idx_champion_lead_configs_company_location", unique: true
    t.index ["company_id"], name: "index_champion_lead_feed_configs_on_company_id"
    t.index ["default_lead_owner_id"], name: "index_champion_lead_feed_configs_on_default_lead_owner_id"
    t.index ["location_id"], name: "index_champion_lead_feed_configs_on_location_id"
  end

  create_table "chart_of_accounts", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "account_number", null: false
    t.string "name", null: false
    t.string "description"
    t.string "account_type", null: false
    t.string "sub_type"
    t.string "normal_balance", null: false
    t.bigint "parent_id"
    t.boolean "is_header", default: false
    t.boolean "is_active", default: true
    t.boolean "is_system", default: false
    t.string "qbo_account_id"
    t.integer "position", default: 0
    t.bigint "bank_account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "opening_balance", precision: 12, scale: 2, default: "0.0"
    t.date "opening_balance_date"
    t.index ["bank_account_id"], name: "index_chart_of_accounts_on_bank_account_id"
    t.index ["company_id", "account_number"], name: "index_chart_of_accounts_on_company_id_and_account_number", unique: true
    t.index ["company_id", "account_type"], name: "index_chart_of_accounts_on_company_id_and_account_type"
    t.index ["company_id", "parent_id"], name: "index_chart_of_accounts_on_company_id_and_parent_id"
    t.index ["company_id"], name: "index_chart_of_accounts_on_company_id"
    t.index ["is_active"], name: "index_chart_of_accounts_on_is_active"
    t.index ["parent_id"], name: "index_chart_of_accounts_on_parent_id"
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
    t.string "communicable_type"
    t.integer "communicable_id"
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
    t.integer "company_id"
    t.integer "user_id"
    t.bigint "workflow_run_id"
    t.string "workflow_step_id"
    t.bigint "campaign_send_id"
    t.index ["campaign_send_id"], name: "index_communications_on_campaign_send_id"
    t.index ["channel"], name: "index_communications_on_channel"
    t.index ["communicable_type", "communicable_id"], name: "index_communications_on_communicable"
    t.index ["communication_thread_id"], name: "index_communications_on_communication_thread_id"
    t.index ["company_id"], name: "index_communications_on_company_id"
    t.index ["created_at"], name: "index_communications_on_created_at"
    t.index ["direction"], name: "index_communications_on_direction"
    t.index ["external_id"], name: "index_communications_on_external_id"
    t.index ["portal_visible"], name: "index_communications_on_portal_visible"
    t.index ["scheduled_for"], name: "index_communications_on_scheduled_for"
    t.index ["scheduled_status", "scheduled_for"], name: "index_communications_on_scheduled_status_and_scheduled_for"
    t.index ["scheduled_status"], name: "index_communications_on_scheduled_status"
    t.index ["status"], name: "index_communications_on_status"
    t.index ["template_id"], name: "index_communications_on_template_id"
    t.index ["user_id"], name: "index_communications_on_user_id"
    t.index ["workflow_run_id"], name: "index_communications_on_workflow_run_id"
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
    t.jsonb "verified_email_domains", default: []
    t.string "public_inventory_token"
    t.jsonb "public_inventory_settings", default: {}
    t.jsonb "pipeline_stages"
    t.string "sms_provisioning_mode", default: "platform", null: false
    t.integer "sms_monthly_limit", default: 2000, null: false
    t.string "phone"
    t.string "email"
    t.string "address_line1"
    t.string "address_line2"
    t.string "city"
    t.string "state"
    t.string "zip_code"
    t.string "country", default: "US"
    t.jsonb "allowed_form_states", default: [], null: false
    t.jsonb "state_tax_rates", default: {}, null: false
    t.string "meta_catalog_token"
    t.string "industry", default: "manufactured_housing", null: false
    t.jsonb "deal_desk_settings", default: {}, null: false
    t.string "account_number"
    t.index ["account_number"], name: "index_companies_on_account_number", unique: true
    t.index ["allowed_form_states"], name: "idx_companies_form_states", using: :gin
    t.index ["custom_domain"], name: "index_companies_on_custom_domain"
    t.index ["default_pack_amount"], name: "index_companies_on_default_pack_amount"
    t.index ["domain"], name: "index_companies_on_domain", unique: true
    t.index ["external_payments_id"], name: "index_companies_on_external_payments_id"
    t.index ["industry"], name: "index_companies_on_industry"
    t.index ["is_demo"], name: "index_companies_on_is_demo"
    t.index ["loan_settings"], name: "index_companies_on_loan_settings", using: :gin
    t.index ["public_inventory_settings"], name: "index_companies_on_public_inventory_settings", using: :gin
    t.index ["public_inventory_token"], name: "index_companies_on_public_inventory_token", unique: true
    t.index ["quickbooks_realm_id"], name: "index_companies_on_quickbooks_realm_id"
    t.index ["quickbooks_scope"], name: "index_companies_on_quickbooks_scope"
    t.index ["sms_provisioning_mode"], name: "index_companies_on_sms_provisioning_mode"
    t.index ["status"], name: "index_companies_on_status"
    t.index ["subdomain"], name: "index_companies_on_subdomain", unique: true
    t.index ["subscription_tier"], name: "index_companies_on_subscription_tier"
    t.index ["use_rbac_system"], name: "index_companies_on_use_rbac_system"
    t.index ["verified_email_domains"], name: "idx_companies_verified_domains", using: :gin
  end

  create_table "company_allowance_defaults", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "category", null: false
    t.string "name", null: false
    t.decimal "standard_allowance", precision: 15, scale: 2
    t.decimal "maximum_allowance", precision: 15, scale: 2
    t.decimal "dealer_cost", precision: 15, scale: 2
    t.decimal "dealer_price", precision: 15, scale: 2
    t.string "pricing_basis"
    t.string "material"
    t.decimal "wind_zone2_adder_per_side", precision: 15, scale: 2
    t.decimal "wind_zone3_adder_per_side", precision: 15, scale: 2
    t.boolean "is_seeded", default: false, null: false
    t.boolean "active", default: true, null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "category", "name"], name: "idx_company_allowance_defaults_uniq", unique: true
    t.index ["company_id"], name: "index_company_allowance_defaults_on_company_id"
  end

  create_table "company_domains", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "website_id"
    t.string "hostname", null: false
    t.string "domain_root"
    t.string "cloudflare_custom_hostname_id"
    t.string "verification_status"
    t.jsonb "verification_records", default: {}
    t.string "ssl_status"
    t.datetime "ssl_issued_at"
    t.datetime "ssl_expires_at"
    t.string "cname_target"
    t.datetime "dns_checked_at"
    t.string "dns_error"
    t.boolean "active", default: false
    t.datetime "activated_at"
    t.datetime "deactivated_at"
    t.boolean "force_ssl", default: true
    t.boolean "force_www", default: false
    t.string "redirect_type"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cloudflare_custom_hostname_id"], name: "index_company_domains_on_cloudflare_custom_hostname_id"
    t.index ["company_id", "active"], name: "index_company_domains_on_company_id_and_active"
    t.index ["company_id"], name: "index_company_domains_on_company_id"
    t.index ["hostname"], name: "index_company_domains_on_hostname", unique: true
    t.index ["verification_status"], name: "index_company_domains_on_verification_status"
    t.index ["website_id"], name: "index_company_domains_on_website_id"
  end

  create_table "company_email_connections", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "provider", null: false
    t.string "email_address", null: false
    t.string "display_name"
    t.string "smtp_host"
    t.integer "smtp_port", default: 587
    t.string "smtp_username"
    t.text "smtp_password_encrypted"
    t.string "smtp_authentication", default: "plain"
    t.boolean "smtp_enable_tls", default: true
    t.boolean "smtp_enable_starttls", default: true
    t.text "oauth_token_encrypted"
    t.text "oauth_refresh_token_encrypted"
    t.datetime "oauth_expires_at"
    t.string "oauth_provider"
    t.boolean "is_active", default: true
    t.datetime "verified_at"
    t.datetime "last_used_at"
    t.datetime "last_error_at"
    t.text "last_error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_company_email_connections_on_company_id", unique: true
  end

  create_table "company_floor_plan_option_overrides", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "floor_plan_option_id", null: false
    t.decimal "dealer_cost", precision: 10, scale: 2
    t.decimal "retail_price", precision: 10, scale: 2
    t.boolean "is_hidden", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "floor_plan_option_id"], name: "idx_company_option_overrides_unique", unique: true
    t.index ["company_id"], name: "index_company_floor_plan_option_overrides_on_company_id"
    t.index ["floor_plan_option_id"], name: "idx_on_floor_plan_option_id_8747bca926"
  end

  create_table "company_floor_plans", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "floor_plan_id", null: false
    t.boolean "is_visible", default: true, null: false
    t.decimal "dealer_cost", precision: 10, scale: 2
    t.decimal "retail_price", precision: 10, scale: 2
    t.string "markup_type"
    t.decimal "markup_value", precision: 10, scale: 2
    t.string "custom_name"
    t.text "custom_description"
    t.integer "display_order", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "floor_plan_id"], name: "index_company_floor_plans_on_company_id_and_floor_plan_id", unique: true
    t.index ["company_id"], name: "index_company_floor_plans_on_company_id"
    t.index ["floor_plan_id"], name: "index_company_floor_plans_on_floor_plan_id"
    t.index ["is_visible"], name: "index_company_floor_plans_on_is_visible"
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
    t.string "contact_name"
    t.string "contact_email"
    t.string "contact_phone"
    t.string "claim_email"
    t.string "claim_contact_name"
    t.index ["active"], name: "index_company_manufacturers_on_active"
    t.index ["company_id", "manufacturer_id"], name: "index_company_manufacturers_on_company_and_manufacturer", unique: true
    t.index ["company_id"], name: "index_company_manufacturers_on_company_id"
    t.index ["manufacturer_id"], name: "index_company_manufacturers_on_manufacturer_id"
  end

  create_table "configurations", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "floor_plan_id", null: false
    t.bigint "user_id"
    t.string "configurable_type"
    t.bigint "configurable_id"
    t.string "name"
    t.jsonb "selections", default: []
    t.decimal "base_price", precision: 10, scale: 2
    t.decimal "options_total", precision: 10, scale: 2
    t.decimal "total_price", precision: 10, scale: 2
    t.decimal "price_range_low", precision: 10, scale: 2
    t.decimal "price_range_high", precision: 10, scale: 2
    t.string "public_token", null: false
    t.string "status", default: "draft", null: false
    t.string "customer_name"
    t.string "customer_email"
    t.string "customer_phone"
    t.datetime "shared_at"
    t.datetime "viewed_at"
    t.datetime "quoted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "status"], name: "index_configurations_on_company_id_and_status"
    t.index ["company_id"], name: "index_configurations_on_company_id"
    t.index ["configurable_type", "configurable_id"], name: "index_configurations_on_configurable"
    t.index ["configurable_type", "configurable_id"], name: "index_configurations_on_configurable_type_and_configurable_id"
    t.index ["floor_plan_id"], name: "index_configurations_on_floor_plan_id"
    t.index ["public_token"], name: "index_configurations_on_public_token", unique: true
    t.index ["status"], name: "index_configurations_on_status"
    t.index ["user_id"], name: "index_configurations_on_user_id"
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
    t.jsonb "custom_field_values", default: {}, null: false
    t.string "delivery_street"
    t.string "delivery_city"
    t.string "delivery_state"
    t.string "delivery_zip"
    t.string "delivery_country"
    t.boolean "email_invalid", default: false, null: false
    t.boolean "opt_in_sms", default: false, null: false
    t.integer "preferred_bedrooms"
    t.integer "preferred_bathrooms"
    t.integer "preferred_min_sqft"
    t.integer "preferred_max_sqft"
    t.string "preferred_home_type"
    t.bigint "preferred_vehicle_id"
    t.string "budget_range"
    t.index ["account_id"], name: "index_contacts_on_account_id"
    t.index ["company_id", "location_id"], name: "index_contacts_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_contacts_on_company_id"
    t.index ["is_deleted"], name: "index_contacts_on_is_deleted"
    t.index ["location_id"], name: "index_contacts_on_location_id"
    t.index ["opt_in_sms"], name: "index_contacts_on_opt_in_sms"
    t.index ["opt_out_email"], name: "index_contacts_on_opt_out_email"
    t.index ["opt_out_sms"], name: "index_contacts_on_opt_out_sms"
    t.index ["owner_id"], name: "index_contacts_on_owner_id"
    t.index ["preferred_vehicle_id"], name: "index_contacts_on_preferred_vehicle_id"
    t.index ["quickbooks_id"], name: "index_contacts_on_quickbooks_id"
  end

  create_table "contractor_assignments", force: :cascade do |t|
    t.bigint "vendor_id", null: false
    t.string "assignable_type", null: false
    t.bigint "assignable_id", null: false
    t.bigint "company_id", null: false
    t.bigint "assigned_by_id"
    t.string "status", default: "assigned"
    t.datetime "assigned_at"
    t.datetime "accepted_at"
    t.datetime "completed_at"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "submitted_for_review", default: false
    t.datetime "submitted_for_review_at"
    t.string "review_status"
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_id"
    t.text "review_notes"
    t.text "completion_summary"
    t.jsonb "completion_photos", default: []
    t.text "revision_notes"
    t.integer "revision_count", default: 0
    t.datetime "notified_at"
    t.datetime "review_notified_at"
    t.datetime "notification_paused_at"
    t.datetime "notification_skipped_at"
    t.index ["assignable_type", "assignable_id"], name: "index_contractor_assignments_on_assignable"
    t.index ["assigned_by_id"], name: "index_contractor_assignments_on_assigned_by_id"
    t.index ["company_id"], name: "index_contractor_assignments_on_company_id"
    t.index ["notification_paused_at"], name: "index_contractor_assignments_on_notification_paused_at"
    t.index ["notification_skipped_at"], name: "index_contractor_assignments_on_notification_skipped_at"
    t.index ["notified_at"], name: "index_contractor_assignments_on_notified_at"
    t.index ["review_notified_at"], name: "index_contractor_assignments_on_review_notified_at"
    t.index ["review_status"], name: "index_contractor_assignments_on_review_status"
    t.index ["reviewed_by_id"], name: "index_contractor_assignments_on_reviewed_by_id"
    t.index ["status"], name: "index_contractor_assignments_on_status"
    t.index ["vendor_id"], name: "index_contractor_assignments_on_vendor_id"
  end

  create_table "custom_field_migrations", force: :cascade do |t|
    t.bigint "source_custom_field_id", null: false
    t.string "target_module", null: false
    t.bigint "target_custom_field_id"
    t.string "migration_type", default: "create_new", null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_custom_field_migrations_on_company_id"
    t.index ["source_custom_field_id", "target_module"], name: "idx_cf_migrations_source_target_module", unique: true
    t.index ["source_custom_field_id"], name: "index_custom_field_migrations_on_source_custom_field_id"
    t.index ["target_custom_field_id"], name: "index_custom_field_migrations_on_target_custom_field_id"
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
    t.boolean "hidden", default: false, null: false
    t.string "visibility", default: "internal", null: false
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

  create_table "deal_desk_scenarios", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.bigint "deal_id", null: false
    t.bigint "vehicle_id"
    t.bigint "created_by_id"
    t.string "label"
    t.string "status", default: "active", null: false
    t.date "valid_through"
    t.datetime "selected_at"
    t.decimal "trade_allowance", precision: 15, scale: 2, default: "0.0"
    t.decimal "trade_payoff", precision: 15, scale: 2, default: "0.0"
    t.decimal "cash_down", precision: 15, scale: 2, default: "0.0"
    t.decimal "rebates", precision: 15, scale: 2, default: "0.0"
    t.jsonb "fees", default: {}, null: false
    t.jsonb "fni_products", default: [], null: false
    t.bigint "lender_program_id"
    t.string "lender_tier"
    t.decimal "apr", precision: 6, scale: 3
    t.string "rate_source"
    t.integer "term_months"
    t.string "tax_mode", default: "full_price", null: false
    t.decimal "tax_rate", precision: 8, scale: 5, default: "0.0"
    t.decimal "unit_price_snapshot", precision: 15, scale: 2
    t.decimal "unit_cost_snapshot", precision: 15, scale: 2
    t.decimal "amount_financed", precision: 15, scale: 2
    t.decimal "monthly_payment", precision: 15, scale: 2
    t.decimal "out_the_door", precision: 15, scale: 2
    t.decimal "front_gross", precision: 15, scale: 2
    t.decimal "back_gross", precision: 15, scale: 2
    t.decimal "dealer_gross", precision: 15, scale: 2
    t.bigint "unit_location_id"
    t.integer "unit_days_on_lot"
    t.boolean "is_cross_location", default: false, null: false
    t.bigint "quote_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "apr_override", precision: 6, scale: 3
    t.jsonb "line_items", default: []
    t.index ["company_id", "status"], name: "index_deal_desk_scenarios_on_company_id_and_status"
    t.index ["company_id"], name: "index_deal_desk_scenarios_on_company_id"
    t.index ["created_by_id"], name: "index_deal_desk_scenarios_on_created_by_id"
    t.index ["deal_id", "status"], name: "index_deal_desk_scenarios_on_deal_id_and_status"
    t.index ["deal_id"], name: "index_deal_desk_scenarios_on_deal_id"
    t.index ["lender_program_id"], name: "index_deal_desk_scenarios_on_lender_program_id"
    t.index ["location_id"], name: "index_deal_desk_scenarios_on_location_id"
    t.index ["quote_id"], name: "index_deal_desk_scenarios_on_quote_id"
    t.index ["valid_through"], name: "index_deal_desk_scenarios_on_valid_through"
    t.index ["vehicle_id"], name: "index_deal_desk_scenarios_on_vehicle_id"
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
    t.string "discount_type", default: "fixed", null: false
    t.string "source_type"
    t.decimal "cost", precision: 12, scale: 2, default: "0.0"
    t.index ["deal_id", "product_id"], name: "index_deal_products_on_deal_id_and_product_id"
    t.index ["deal_id"], name: "index_deal_products_on_deal_id"
    t.index ["discount_type"], name: "index_deal_products_on_discount_type"
    t.index ["product_id"], name: "index_deal_products_on_product_id"
    t.index ["source_type"], name: "index_deal_products_on_source_type"
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
    t.string "deal_number"
    t.jsonb "custom_field_values", default: {}, null: false
    t.string "billing_street"
    t.string "billing_city"
    t.string "billing_state"
    t.string "billing_zip"
    t.string "billing_country"
    t.string "delivery_street"
    t.string "delivery_city"
    t.string "delivery_state"
    t.string "delivery_zip"
    t.string "delivery_country"
    t.bigint "project_id"
    t.decimal "dealer_discount", precision: 15, scale: 2, default: "0.0"
    t.decimal "sales_event_discount", precision: 15, scale: 2, default: "0.0"
    t.decimal "manager_discount", precision: 15, scale: 2, default: "0.0"
    t.decimal "preferred_payment_discount", precision: 15, scale: 2, default: "0.0"
    t.decimal "multi_unit_discount", precision: 15, scale: 2, default: "0.0"
    t.decimal "subtotal_1", precision: 15, scale: 2, default: "0.0"
    t.decimal "subtotal_2", precision: 15, scale: 2, default: "0.0"
    t.decimal "tax_amount", precision: 15, scale: 2, default: "0.0"
    t.decimal "total_amount", precision: 15, scale: 2, default: "0.0"
    t.decimal "down_payment", precision: 15, scale: 2, default: "0.0"
    t.decimal "additional_payment", precision: 15, scale: 2, default: "0.0"
    t.decimal "unpaid_balance", precision: 15, scale: 2, default: "0.0"
    t.datetime "last_activity_at"
    t.decimal "home_cost", precision: 15, scale: 2
    t.decimal "reconditioning_cost", precision: 15, scale: 2
    t.decimal "floor_plan_interest", precision: 15, scale: 2
    t.decimal "delivery_setup_cost", precision: 15, scale: 2
    t.decimal "front_gross", precision: 15, scale: 2
    t.decimal "back_gross", precision: 15, scale: 2
    t.decimal "total_gross", precision: 15, scale: 2
    t.decimal "commission_amount", precision: 15, scale: 2
    t.decimal "net_deal_profit", precision: 15, scale: 2
    t.boolean "gl_posted", default: false
    t.datetime "gl_posted_at"
    t.bigint "gl_journal_entry_id"
    t.decimal "state_tax_rate", precision: 8, scale: 5
    t.decimal "county_tax_rate", precision: 8, scale: 5
    t.decimal "city_tax_rate", precision: 8, scale: 5
    t.decimal "total_tax_amount", precision: 15, scale: 2
    t.boolean "tax_posted", default: false, null: false
    t.jsonb "tax_journal_entry_ids", default: [], null: false
    t.boolean "commission_posted", default: false, null: false
    t.datetime "commission_posted_at"
    t.bigint "commission_journal_entry_id"
    t.string "payment_type"
    t.string "lender_name"
    t.decimal "financed_amount", precision: 12, scale: 2
    t.date "down_payment_due_date"
    t.integer "deal_invoice_id"
    t.bigint "lender_id"
    t.jsonb "deal_desk_baseline"
    t.index ["account_id", "stage"], name: "index_deals_on_account_id_and_stage"
    t.index ["account_id"], name: "index_deals_on_account_id"
    t.index ["assigned_to"], name: "index_deals_on_assigned_to"
    t.index ["commission_plan_id", "delivery_date"], name: "index_deals_on_plan_and_delivery"
    t.index ["commission_plan_id"], name: "index_deals_on_commission_plan_id"
    t.index ["company_id", "deal_number"], name: "index_deals_on_company_id_and_deal_number", unique: true
    t.index ["company_id", "delivery_date"], name: "index_deals_on_company_and_delivery"
    t.index ["company_id", "location_id"], name: "index_deals_on_company_id_and_location_id"
    t.index ["company_id", "project_id"], name: "idx_deals_company_project"
    t.index ["company_id"], name: "index_deals_on_company_id"
    t.index ["contact_id"], name: "index_deals_on_contact_id"
    t.index ["custom_field_values"], name: "index_deals_on_custom_field_values", using: :gin
    t.index ["deal_invoice_id"], name: "index_deals_on_deal_invoice_id"
    t.index ["deal_type"], name: "index_deals_on_deal_type"
    t.index ["deleted_at"], name: "index_deals_on_deleted_at"
    t.index ["desk_manager_id"], name: "index_deals_on_desk_manager_id"
    t.index ["expected_close_date"], name: "index_deals_on_expected_close_date"
    t.index ["finance_manager_id"], name: "index_deals_on_finance_manager_id"
    t.index ["gl_journal_entry_id"], name: "index_deals_on_gl_journal_entry_id"
    t.index ["gl_posted"], name: "index_deals_on_gl_posted"
    t.index ["lender_id"], name: "index_deals_on_lender_id"
    t.index ["location_id"], name: "index_deals_on_location_id"
    t.index ["lost_at"], name: "index_deals_on_lost_at"
    t.index ["owner_id"], name: "index_deals_on_owner_id"
    t.index ["payment_type"], name: "index_deals_on_payment_type"
    t.index ["primary_salesperson_id", "delivery_date"], name: "index_deals_on_salesperson_and_delivery"
    t.index ["project_id"], name: "index_deals_on_project_id"
    t.index ["sales_manager_id"], name: "index_deals_on_sales_manager_id"
    t.index ["secondary_salesperson_id"], name: "index_deals_on_secondary_salesperson_id"
    t.index ["source_id"], name: "index_deals_on_source_id"
    t.index ["stage"], name: "index_deals_on_stage"
    t.index ["territory_id", "stage"], name: "index_deals_on_territory_id_and_stage"
    t.index ["territory_id"], name: "index_deals_on_territory_id"
    t.index ["user_id", "last_activity_at"], name: "index_deals_on_user_id_and_last_activity_at"
    t.index ["user_id", "stage"], name: "index_deals_on_user_id_and_stage"
    t.index ["user_id"], name: "index_deals_on_user_id"
    t.index ["vehicle_id"], name: "index_deals_on_vehicle_id"
    t.index ["vertical"], name: "index_deals_on_vertical"
    t.index ["won_at"], name: "index_deals_on_won_at"
  end

  create_table "draw_schedule_templates", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.boolean "is_default", default: false
    t.jsonb "draws", default: []
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "addon_mode", default: "included", null: false
    t.string "tax_timing", default: "per_draw", null: false
    t.integer "location_id"
    t.index ["company_id", "is_default"], name: "idx_draw_templates_company_default"
    t.index ["company_id", "location_id", "is_default"], name: "idx_draw_templates_company_location_default"
    t.index ["company_id"], name: "index_draw_schedule_templates_on_company_id"
  end

  create_table "entity_buyers", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "contact_id", null: false
    t.string "buyable_type", null: false
    t.bigint "buyable_id", null: false
    t.string "role", default: "co_buyer", null: false
    t.integer "position", default: 0
    t.text "notes"
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["buyable_type", "buyable_id"], name: "index_entity_buyers_on_buyable"
    t.index ["company_id", "buyable_type", "buyable_id"], name: "index_entity_buyers_on_company_buyable"
    t.index ["company_id"], name: "index_entity_buyers_on_company_id"
    t.index ["contact_id", "buyable_type", "buyable_id"], name: "index_entity_buyers_on_contact_buyable", unique: true, where: "(is_deleted = false)"
    t.index ["contact_id"], name: "index_entity_buyers_on_contact_id"
  end

  create_table "export_jobs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id", null: false
    t.string "module_type", null: false
    t.string "status", default: "pending", null: false
    t.string "format", default: "csv", null: false
    t.jsonb "filters", default: {}, null: false
    t.jsonb "selected_fields", default: [], null: false
    t.integer "row_count", default: 0, null: false
    t.string "file_url"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_export_jobs_on_company_id"
    t.index ["module_type"], name: "index_export_jobs_on_module_type"
    t.index ["status"], name: "index_export_jobs_on_status"
    t.index ["user_id"], name: "index_export_jobs_on_user_id"
  end

  create_table "facebook_integrations", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "page_id", null: false
    t.string "page_name"
    t.text "page_access_token"
    t.text "user_access_token"
    t.datetime "token_expires_at"
    t.string "status", default: "active"
    t.jsonb "subscribed_fields", default: ["leadgen"]
    t.jsonb "field_mapping", default: {}
    t.bigint "default_source_id"
    t.bigint "default_owner_id"
    t.bigint "default_workflow_id"
    t.integer "lead_count", default: 0
    t.datetime "last_lead_at"
    t.jsonb "metadata", default: {}
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_facebook_integrations_on_company_id"
    t.index ["page_id"], name: "index_facebook_integrations_on_page_id"
    t.index ["status"], name: "index_facebook_integrations_on_status"
  end

  create_table "factories", force: :cascade do |t|
    t.bigint "manufacturer_id", null: false
    t.string "name", null: false
    t.string "code", null: false
    t.string "address"
    t.string "city"
    t.string "state"
    t.string "zip"
    t.decimal "latitude", precision: 10, scale: 7
    t.decimal "longitude", precision: 10, scale: 7
    t.string "contact_email"
    t.string "contact_phone"
    t.boolean "is_active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["is_active"], name: "index_factories_on_is_active"
    t.index ["manufacturer_id", "code"], name: "index_factories_on_manufacturer_id_and_code", unique: true
    t.index ["manufacturer_id"], name: "index_factories_on_manufacturer_id"
  end

  create_table "fee_templates", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.string "fee_type", default: "other", null: false
    t.decimal "default_amount", precision: 15, scale: 2, default: "0.0", null: false
    t.boolean "taxable", default: false, null: false
    t.string "applies_to", default: "all", null: false
    t.boolean "active", default: true, null: false
    t.boolean "is_seeded", default: false, null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "active"], name: "index_fee_templates_on_company_id_and_active"
    t.index ["company_id"], name: "index_fee_templates_on_company_id"
  end

  create_table "field_option_overrides", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "module_name", null: false
    t.string "field_key", null: false
    t.jsonb "options", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "module_name", "field_key"], name: "idx_field_option_overrides_unique", unique: true
    t.index ["company_id"], name: "index_field_option_overrides_on_company_id"
  end

  create_table "fiscal_periods", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.integer "fiscal_year", null: false
    t.integer "period_number", null: false
    t.date "start_date", null: false
    t.date "end_date", null: false
    t.string "status", default: "open"
    t.datetime "closed_at"
    t.bigint "closed_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["closed_by_id"], name: "index_fiscal_periods_on_closed_by_id"
    t.index ["company_id", "fiscal_year", "period_number"], name: "idx_fiscal_periods_company_year_period", unique: true
    t.index ["company_id", "status"], name: "index_fiscal_periods_on_company_id_and_status"
    t.index ["company_id"], name: "index_fiscal_periods_on_company_id"
  end

  create_table "floor_plan_option_applicabilities", force: :cascade do |t|
    t.bigint "floor_plan_id", null: false
    t.bigint "floor_plan_option_id", null: false
    t.boolean "is_default_for_model", default: false, null: false
    t.decimal "price_dealer_override", precision: 10, scale: 2
    t.decimal "price_retail_override", precision: 10, scale: 2
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["floor_plan_id", "floor_plan_option_id"], name: "idx_fp_option_applicability_unique", unique: true
    t.index ["floor_plan_id"], name: "index_floor_plan_option_applicabilities_on_floor_plan_id"
    t.index ["floor_plan_option_id"], name: "idx_on_floor_plan_option_id_e985b29c0c"
    t.index ["is_default_for_model"], name: "idx_on_is_default_for_model_2782a513db"
  end

  create_table "floor_plan_options", force: :cascade do |t|
    t.bigint "option_category_id", null: false
    t.string "name", null: false
    t.text "description"
    t.string "image_url"
    t.decimal "price_impact_low", precision: 10, scale: 2
    t.decimal "price_impact_high", precision: 10, scale: 2
    t.jsonb "compatibility_rules", default: {}
    t.integer "display_order", default: 0
    t.boolean "is_default", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "option_code"
    t.decimal "price_dealer", precision: 10, scale: 2
    t.decimal "price_retail", precision: 10, scale: 2
    t.string "swatch_image_url"
    t.string "material_type"
    t.string "dimensions"
    t.string "series_restriction"
    t.bigint "factory_id"
    t.boolean "is_standard_included", default: false, null: false
    t.index ["factory_id", "option_code"], name: "index_floor_plan_options_on_factory_id_and_option_code"
    t.index ["factory_id"], name: "index_floor_plan_options_on_factory_id"
    t.index ["is_default"], name: "index_floor_plan_options_on_is_default"
    t.index ["is_standard_included"], name: "index_floor_plan_options_on_is_standard_included"
    t.index ["option_category_id", "display_order"], name: "idx_on_option_category_id_display_order_92fbf53154"
    t.index ["option_category_id"], name: "index_floor_plan_options_on_option_category_id"
    t.index ["option_code"], name: "index_floor_plan_options_on_option_code"
    t.index ["series_restriction"], name: "index_floor_plan_options_on_series_restriction"
  end

  create_table "floor_plans", force: :cascade do |t|
    t.bigint "manufacturer_id", null: false
    t.bigint "factory_id"
    t.string "name", null: false
    t.string "model_code", null: false
    t.string "series"
    t.integer "beds"
    t.decimal "baths", precision: 3, scale: 1
    t.integer "sqft"
    t.decimal "width_feet", precision: 6, scale: 2
    t.decimal "length_feet", precision: 6, scale: 2
    t.jsonb "specifications", default: {}
    t.jsonb "images_array", default: []
    t.decimal "base_price_low", precision: 10, scale: 2
    t.decimal "base_price_high", precision: 10, scale: 2
    t.decimal "suggested_retail_low", precision: 10, scale: 2
    t.decimal "suggested_retail_high", precision: 10, scale: 2
    t.boolean "is_active", default: true, null: false
    t.string "scraper_source_url"
    t.datetime "last_scraped_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "net_price", precision: 10, scale: 2
    t.string "box_size"
    t.string "home_type", default: "hud"
    t.string "s3_folder_path"
    t.string "virtual_tour_url"
    t.string "spec_sheet_url"
    t.date "price_effective_date"
    t.string "brand"
    t.index ["brand"], name: "index_floor_plans_on_brand"
    t.index ["factory_id"], name: "index_floor_plans_on_factory_id"
    t.index ["home_type"], name: "index_floor_plans_on_home_type"
    t.index ["is_active"], name: "index_floor_plans_on_is_active"
    t.index ["manufacturer_id", "model_code"], name: "index_floor_plans_on_manufacturer_id_and_model_code", unique: true
    t.index ["manufacturer_id"], name: "index_floor_plans_on_manufacturer_id"
    t.index ["net_price"], name: "index_floor_plans_on_net_price"
    t.index ["series"], name: "index_floor_plans_on_series"
  end

  create_table "fni_products", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.string "product_type", default: "other", null: false
    t.decimal "default_price", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "default_cost", precision: 15, scale: 2, default: "0.0", null: false
    t.boolean "active", default: true, null: false
    t.boolean "is_seeded", default: false, null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "active"], name: "index_fni_products_on_company_id_and_active"
    t.index ["company_id"], name: "index_fni_products_on_company_id"
  end

  create_table "import_jobs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id", null: false
    t.string "module_type", null: false
    t.string "status", default: "pending", null: false
    t.string "source_filename"
    t.string "source_file_url"
    t.string "image_zip_url"
    t.integer "total_rows", default: 0, null: false
    t.integer "processed_rows", default: 0, null: false
    t.integer "success_count", default: 0, null: false
    t.integer "error_count", default: 0, null: false
    t.integer "skipped_count", default: 0, null: false
    t.jsonb "column_mapping", default: {}, null: false
    t.string "duplicate_strategy", default: "skip"
    t.jsonb "duplicate_match_fields", default: [], null: false
    t.jsonb "options", default: {}, null: false
    t.jsonb "error_log", default: [], null: false
    t.jsonb "created_record_ids", default: [], null: false
    t.jsonb "updated_record_snapshots", default: [], null: false
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "module_type", "status"], name: "index_import_jobs_on_company_id_and_module_type_and_status"
    t.index ["company_id"], name: "index_import_jobs_on_company_id"
    t.index ["module_type"], name: "index_import_jobs_on_module_type"
    t.index ["status"], name: "index_import_jobs_on_status"
    t.index ["user_id"], name: "index_import_jobs_on_user_id"
  end

  create_table "import_templates", force: :cascade do |t|
    t.bigint "company_id"
    t.string "module_type", null: false
    t.string "name", null: false
    t.text "description"
    t.jsonb "column_mapping", default: {}, null: false
    t.string "duplicate_strategy", default: "skip"
    t.jsonb "duplicate_match_fields", default: [], null: false
    t.jsonb "options", default: {}, null: false
    t.boolean "is_platform_default", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "module_type"], name: "index_import_templates_on_company_id_and_module_type"
    t.index ["company_id"], name: "index_import_templates_on_company_id"
    t.index ["module_type"], name: "index_import_templates_on_module_type"
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
    t.bigint "notified_user_id"
    t.json "field_mappings", default: {}
    t.boolean "auto_create_lead", default: true
    t.boolean "auto_create_activity", default: true
    t.index ["company_id"], name: "index_intake_forms_on_company_id"
    t.index ["notified_user_id"], name: "index_intake_forms_on_notified_user_id"
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

  create_table "inventory_features", force: :cascade do |t|
    t.bigint "vehicle_id", null: false
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.string "category"
    t.boolean "is_standard", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "idx_inv_features_category"
    t.index ["company_id", "name"], name: "idx_inv_features_company_name"
    t.index ["company_id"], name: "index_inventory_features_on_company_id"
    t.index ["vehicle_id", "name"], name: "idx_inv_features_vehicle_name", unique: true
    t.index ["vehicle_id"], name: "index_inventory_features_on_vehicle_id"
  end

  create_table "inventory_packages", force: :cascade do |t|
    t.bigint "vehicle_id", null: false
    t.bigint "package_template_id"
    t.string "name", null: false
    t.text "description"
    t.decimal "price", precision: 12, scale: 2, default: "0.0"
    t.boolean "include_in_total", default: true, null: false
    t.boolean "show_price_in_marketing", default: false, null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "taxable", default: false
    t.decimal "tax_rate", precision: 5, scale: 3
    t.decimal "cost", precision: 12, scale: 2
    t.index ["package_template_id"], name: "index_inventory_packages_on_package_template_id"
    t.index ["vehicle_id", "position"], name: "index_inventory_packages_on_vehicle_id_and_position"
    t.index ["vehicle_id"], name: "index_inventory_packages_on_vehicle_id"
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

  create_table "invoice_inventory_usages", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "invoice_id", null: false
    t.bigint "invoice_item_id", null: false
    t.string "itemable_type", null: false
    t.integer "itemable_id", null: false
    t.decimal "quantity_used", precision: 10, scale: 2, default: "1.0", null: false
    t.datetime "marked_at"
    t.bigint "marked_by_id"
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "marked", default: false, null: false
    t.index ["company_id"], name: "index_invoice_inventory_usages_on_company_id"
    t.index ["invoice_id"], name: "index_invoice_inventory_usages_on_invoice_id"
    t.index ["invoice_item_id", "itemable_type", "itemable_id"], name: "index_invoice_inv_usages_on_item_and_itemable", unique: true
    t.index ["invoice_item_id"], name: "index_invoice_inventory_usages_on_invoice_item_id"
    t.index ["itemable_type", "itemable_id"], name: "idx_on_itemable_type_itemable_id_3830e51cc8"
    t.index ["marked_at"], name: "index_invoice_inventory_usages_on_marked_at"
    t.index ["marked_by_id"], name: "index_invoice_inventory_usages_on_marked_by_id"
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
    t.string "itemable_type"
    t.integer "itemable_id"
    t.string "commission_type", default: "full_commission"
    t.string "category"
    t.decimal "cost", precision: 10, scale: 2, default: "0.0"
    t.boolean "taxable", default: false
    t.decimal "tax_rate", precision: 5, scale: 2, default: "0.0"
    t.text "notes"
    t.index ["invoice_id", "position"], name: "index_invoice_items_on_invoice_id_and_position"
    t.index ["invoice_id"], name: "index_invoice_items_on_invoice_id"
    t.index ["itemable_type", "itemable_id"], name: "index_invoice_items_on_itemable_type_and_itemable_id"
    t.index ["listing_id"], name: "index_invoice_items_on_listing_id"
  end

  create_table "invoice_notes_templates", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.text "notes", null: false
    t.boolean "is_default", default: false
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_invoice_notes_templates_on_company_id"
  end

  create_table "invoice_terms_templates", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.text "terms", null: false
    t.boolean "is_default", default: false
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "is_default"], name: "idx_terms_templates_company_default"
    t.index ["company_id"], name: "index_invoice_terms_templates_on_company_id"
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
    t.integer "sales_rep_id"
    t.integer "quote_id"
    t.jsonb "draw_schedule", default: {}
    t.string "billing_street"
    t.string "billing_city"
    t.string "billing_state"
    t.string "billing_zip"
    t.string "billing_country"
    t.string "delivery_street"
    t.string "delivery_city"
    t.string "delivery_state"
    t.string "delivery_zip"
    t.string "delivery_country"
    t.jsonb "custom_field_values", default: {}, null: false
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
    t.index ["quote_id"], name: "index_invoices_on_quote_id"
    t.index ["recipient_type", "recipient_id"], name: "index_invoices_on_recipient_type_and_recipient_id"
    t.index ["sales_rep_id"], name: "index_invoices_on_sales_rep_id"
    t.index ["source_type", "source_id"], name: "index_invoices_on_source_type_and_source_id"
    t.index ["status"], name: "index_invoices_on_status"
  end

  create_table "journal_entries", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "entry_number"
    t.date "entry_date", null: false
    t.text "memo"
    t.string "source_type", default: "manual"
    t.string "source_entity_type"
    t.bigint "source_entity_id"
    t.boolean "is_adjusting", default: false
    t.boolean "is_closing", default: false
    t.boolean "is_void", default: false
    t.datetime "voided_at"
    t.bigint "voided_by_id"
    t.bigint "posted_by_id"
    t.bigint "reversed_by_id"
    t.integer "fiscal_year"
    t.integer "fiscal_period"
    t.boolean "locked", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "attachments", default: []
    t.index ["company_id", "entry_date"], name: "index_journal_entries_on_company_id_and_entry_date"
    t.index ["company_id", "entry_number"], name: "index_journal_entries_on_company_id_and_entry_number", unique: true
    t.index ["company_id"], name: "index_journal_entries_on_company_id"
    t.index ["fiscal_year", "fiscal_period"], name: "index_journal_entries_on_fiscal_year_and_fiscal_period"
    t.index ["is_void"], name: "index_journal_entries_on_is_void"
    t.index ["posted_by_id"], name: "index_journal_entries_on_posted_by_id"
    t.index ["reversed_by_id"], name: "index_journal_entries_on_reversed_by_id"
    t.index ["source_entity_type", "source_entity_id"], name: "idx_on_source_entity_type_source_entity_id_a5b7b62861"
    t.index ["voided_by_id"], name: "index_journal_entries_on_voided_by_id"
  end

  create_table "journal_entry_lines", force: :cascade do |t|
    t.bigint "journal_entry_id", null: false
    t.bigint "chart_of_account_id", null: false
    t.decimal "debit_amount", precision: 15, scale: 2, default: "0.0"
    t.decimal "credit_amount", precision: 15, scale: 2, default: "0.0"
    t.text "memo"
    t.bigint "location_id"
    t.string "department"
    t.bigint "contact_id"
    t.bigint "deal_id"
    t.bigint "vehicle_id"
    t.integer "position", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chart_of_account_id"], name: "index_journal_entry_lines_on_chart_of_account_id"
    t.index ["contact_id"], name: "index_journal_entry_lines_on_contact_id"
    t.index ["deal_id"], name: "index_journal_entry_lines_on_deal_id"
    t.index ["department"], name: "index_journal_entry_lines_on_department"
    t.index ["journal_entry_id"], name: "index_journal_entry_lines_on_journal_entry_id"
    t.index ["location_id"], name: "index_journal_entry_lines_on_location_id"
    t.index ["vehicle_id"], name: "index_journal_entry_lines_on_vehicle_id"
  end

  create_table "knowledge_articles", force: :cascade do |t|
    t.bigint "knowledge_module_id"
    t.bigint "knowledge_feature_id"
    t.string "title", null: false
    t.string "slug", null: false
    t.text "content"
    t.text "content_html"
    t.text "excerpt"
    t.string "article_type", default: "how_to", null: false
    t.integer "position", default: 0, null: false
    t.boolean "is_published", default: false, null: false
    t.vector "embedding", limit: 1536
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["article_type"], name: "index_knowledge_articles_on_article_type"
    t.index ["embedding"], name: "idx_knowledge_articles_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["is_published", "position"], name: "index_knowledge_articles_on_is_published_and_position"
    t.index ["knowledge_feature_id"], name: "index_knowledge_articles_on_knowledge_feature_id"
    t.index ["knowledge_module_id"], name: "index_knowledge_articles_on_knowledge_module_id"
    t.index ["slug"], name: "index_knowledge_articles_on_slug", unique: true
  end

  create_table "knowledge_change_queue", force: :cascade do |t|
    t.bigint "knowledge_snapshot_id", null: false
    t.string "change_type", null: false
    t.string "entity_type", null: false
    t.string "entity_key", null: false
    t.jsonb "old_value"
    t.jsonb "new_value"
    t.string "status", default: "pending", null: false
    t.bigint "reviewed_by_id"
    t.datetime "reviewed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["change_type"], name: "index_knowledge_change_queue_on_change_type"
    t.index ["entity_key"], name: "index_knowledge_change_queue_on_entity_key"
    t.index ["entity_type", "entity_key"], name: "index_knowledge_change_queue_on_entity_type_and_entity_key"
    t.index ["entity_type"], name: "index_knowledge_change_queue_on_entity_type"
    t.index ["knowledge_snapshot_id"], name: "index_knowledge_change_queue_on_knowledge_snapshot_id"
    t.index ["reviewed_by_id"], name: "index_knowledge_change_queue_on_reviewed_by_id"
    t.index ["status"], name: "index_knowledge_change_queue_on_status"
  end

  create_table "knowledge_entity_aliases", force: :cascade do |t|
    t.string "canonical_key", null: false
    t.string "alias_name", null: false
    t.string "entity_type", default: "module", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["alias_name"], name: "index_knowledge_entity_aliases_on_alias_name"
    t.index ["canonical_key"], name: "index_knowledge_entity_aliases_on_canonical_key"
    t.index ["entity_type", "alias_name"], name: "idx_knowledge_aliases_on_type_and_alias", unique: true
  end

  create_table "knowledge_features", force: :cascade do |t|
    t.bigint "knowledge_module_id", null: false
    t.string "key", null: false
    t.string "name", null: false
    t.text "description"
    t.string "route"
    t.string "ui_selector"
    t.string "permission_key"
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["knowledge_module_id", "key"], name: "index_knowledge_features_on_knowledge_module_id_and_key", unique: true
    t.index ["knowledge_module_id"], name: "index_knowledge_features_on_knowledge_module_id"
    t.index ["permission_key"], name: "index_knowledge_features_on_permission_key"
  end

  create_table "knowledge_intent_patterns", force: :cascade do |t|
    t.string "pattern", null: false
    t.string "intent_type", null: false
    t.string "entity_key"
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_key"], name: "index_knowledge_intent_patterns_on_entity_key"
    t.index ["intent_type"], name: "index_knowledge_intent_patterns_on_intent_type"
    t.index ["priority"], name: "index_knowledge_intent_patterns_on_priority", order: :desc
  end

  create_table "knowledge_modules", force: :cascade do |t|
    t.string "key", null: false
    t.string "name", null: false
    t.text "description"
    t.string "icon"
    t.string "route"
    t.integer "position", default: 0, null: false
    t.boolean "is_active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "category"
    t.index ["category"], name: "index_knowledge_modules_on_category"
    t.index ["is_active", "position"], name: "index_knowledge_modules_on_is_active_and_position"
    t.index ["key"], name: "index_knowledge_modules_on_key", unique: true
  end

  create_table "knowledge_searches", force: :cascade do |t|
    t.bigint "user_id"
    t.string "query", null: false
    t.string "intent_detected"
    t.integer "result_count", default: 0, null: false
    t.string "action_taken"
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_knowledge_searches_on_created_at"
    t.index ["intent_detected"], name: "index_knowledge_searches_on_intent_detected"
    t.index ["user_id"], name: "index_knowledge_searches_on_user_id"
  end

  create_table "knowledge_snapshots", force: :cascade do |t|
    t.datetime "snapshot_at", null: false
    t.string "modules_hash", null: false
    t.integer "features_count", default: 0, null: false
    t.jsonb "changes_detected", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["modules_hash"], name: "index_knowledge_snapshots_on_modules_hash"
    t.index ["snapshot_at"], name: "index_knowledge_snapshots_on_snapshot_at"
  end

  create_table "knowledge_ui_elements", force: :cascade do |t|
    t.bigint "knowledge_feature_id", null: false
    t.string "selector", null: false
    t.string "label"
    t.string "element_type", default: "button", null: false
    t.text "tour_hint"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["element_type"], name: "index_knowledge_ui_elements_on_element_type"
    t.index ["knowledge_feature_id", "selector"], name: "idx_knowledge_ui_elements_on_feature_and_selector", unique: true
    t.index ["knowledge_feature_id"], name: "index_knowledge_ui_elements_on_knowledge_feature_id"
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
    t.string "band"
    t.jsonb "breakdown", default: {}
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
    t.integer "source_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "status"
    t.integer "converted_account_id"
    t.bigint "company_id"
    t.boolean "is_converted", default: false
    t.datetime "converted_at"
    t.bigint "location_id"
    t.integer "owner_id"
    t.string "budget_range"
    t.string "purchase_timeframe"
    t.string "rv_experience"
    t.string "preferred_contact_method"
    t.text "interests_requirements"
    t.jsonb "custom_field_values", default: {}, null: false
    t.bigint "vehicle_id"
    t.string "street"
    t.string "city"
    t.string "state"
    t.string "zip"
    t.string "country"
    t.datetime "last_activity_at"
    t.string "utm_source"
    t.string "utm_medium"
    t.string "utm_campaign"
    t.string "utm_content"
    t.string "utm_term"
    t.bigint "social_post_id"
    t.string "social_intent"
    t.jsonb "survey_answers"
    t.integer "health_score", default: 0
    t.datetime "health_score_updated_at"
    t.datetime "last_activity_scored_at"
    t.boolean "email_invalid", default: false, null: false
    t.boolean "opt_in_sms", default: false, null: false
    t.string "champion_salesforce_id"
    t.string "champion_status"
    t.jsonb "champion_lead_data", default: {}
    t.bigint "champion_config_id"
    t.datetime "champion_accepted_at"
    t.datetime "champion_declined_at"
    t.string "champion_action_token"
    t.datetime "champion_action_token_expires_at"
    t.string "company_name"
    t.string "title"
    t.integer "preferred_bedrooms"
    t.integer "preferred_bathrooms"
    t.integer "preferred_min_sqft"
    t.integer "preferred_max_sqft"
    t.string "preferred_home_type"
    t.datetime "source_created_at"
    t.index ["champion_action_token"], name: "index_leads_on_champion_action_token", unique: true
    t.index ["champion_config_id"], name: "index_leads_on_champion_config_id"
    t.index ["champion_salesforce_id"], name: "index_leads_on_champion_salesforce_id"
    t.index ["company_id", "champion_salesforce_id"], name: "idx_leads_company_champion_sf_id", unique: true
    t.index ["company_id", "location_id"], name: "index_leads_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_leads_on_company_id"
    t.index ["company_name"], name: "index_leads_on_company_name"
    t.index ["converted_account_id"], name: "index_leads_on_converted_account_id"
    t.index ["health_score"], name: "index_leads_on_health_score"
    t.index ["location_id"], name: "index_leads_on_location_id"
    t.index ["opt_in_sms"], name: "index_leads_on_opt_in_sms"
    t.index ["owner_id", "last_activity_at"], name: "index_leads_on_owner_id_and_last_activity_at"
    t.index ["owner_id"], name: "index_leads_on_owner_id"
    t.index ["social_post_id"], name: "index_leads_on_social_post_id"
    t.index ["source_created_at"], name: "index_leads_on_source_created_at"
    t.index ["source_id"], name: "index_leads_on_source_id"
    t.index ["utm_campaign"], name: "index_leads_on_utm_campaign"
    t.index ["utm_medium"], name: "index_leads_on_utm_medium"
    t.index ["utm_source"], name: "index_leads_on_utm_source"
    t.index ["vehicle_id"], name: "index_leads_on_vehicle_id"
  end

  create_table "lender_allowance_items", force: :cascade do |t|
    t.bigint "lender_id", null: false
    t.bigint "company_id", null: false
    t.string "category", null: false
    t.string "name"
    t.decimal "standard_allowance", precision: 15, scale: 2
    t.decimal "maximum_allowance", precision: 15, scale: 2
    t.string "pricing_basis"
    t.string "material"
    t.decimal "wind_zone2_adder_per_side", precision: 15, scale: 2
    t.decimal "wind_zone3_adder_per_side", precision: 15, scale: 2
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "dealer_cost", precision: 15, scale: 2
    t.decimal "dealer_price", precision: 15, scale: 2
    t.integer "position", default: 0
    t.bigint "company_allowance_default_id"
    t.index ["company_allowance_default_id"], name: "index_lender_allowance_items_on_company_allowance_default_id"
    t.index ["company_id"], name: "index_lender_allowance_items_on_company_id"
    t.index ["lender_id"], name: "index_lender_allowance_items_on_lender_id"
  end

  create_table "lender_deletion_items", force: :cascade do |t|
    t.bigint "lender_id", null: false
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.decimal "amount", precision: 15, scale: 2
    t.string "invoice_reference"
    t.decimal "single_amount", precision: 15, scale: 2
    t.decimal "multi_amount", precision: 15, scale: 2
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_lender_deletion_items_on_company_id"
    t.index ["lender_id"], name: "index_lender_deletion_items_on_lender_id"
  end

  create_table "lender_markup_configs", force: :cascade do |t|
    t.bigint "lender_id", null: false
    t.bigint "company_id", null: false
    t.decimal "base_markup_pct", precision: 8, scale: 2, default: "145.0"
    t.integer "max_age_years", default: 4
    t.decimal "vep0_adj_pct", precision: 8, scale: 2, default: "5.0"
    t.decimal "vep1_adj_pct", precision: 8, scale: 2, default: "0.0"
    t.decimal "vep2_adj_pct", precision: 8, scale: 2, default: "-5.0"
    t.decimal "used_onsite_factor_pct", precision: 8, scale: 2, default: "140.0"
    t.decimal "used_delivered_factor_pct", precision: 8, scale: 2, default: "130.0"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_lender_markup_configs_on_company_id"
    t.index ["lender_id"], name: "index_lender_markup_configs_on_lender_id", unique: true
  end

  create_table "lender_program_tiers", force: :cascade do |t|
    t.bigint "lender_program_id", null: false
    t.string "tier_label"
    t.integer "fico_min"
    t.integer "fico_max"
    t.integer "collateral_age_min_years", default: 0
    t.integer "collateral_age_max_years"
    t.decimal "loan_amount_min", precision: 15, scale: 2, default: "0.0"
    t.decimal "loan_amount_max", precision: 15, scale: 2
    t.decimal "rate", precision: 6, scale: 3, null: false
    t.integer "max_term_months", null: false
    t.decimal "max_ltv", precision: 6, scale: 4
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["lender_program_id", "fico_min", "fico_max"], name: "index_lender_tiers_on_program_and_fico"
    t.index ["lender_program_id"], name: "index_lender_program_tiers_on_lender_program_id"
  end

  create_table "lender_programs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "lender_name", null: false
    t.string "program_name", null: false
    t.string "collateral_type"
    t.text "notes"
    t.boolean "active", default: true, null: false
    t.boolean "is_seeded", default: false, null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "active"], name: "index_lender_programs_on_company_id_and_active"
    t.index ["company_id"], name: "index_lender_programs_on_company_id"
  end

  create_table "lenders", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.string "contact_name"
    t.string "phone"
    t.string "email"
    t.string "website"
    t.text "notes"
    t.boolean "active", default: true, null: false
    t.boolean "is_deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "name"], name: "index_lenders_on_company_id_and_name"
    t.index ["company_id"], name: "index_lenders_on_company_id"
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

  create_table "location_email_connections", force: :cascade do |t|
    t.bigint "location_id", null: false
    t.bigint "company_id", null: false
    t.string "provider", null: false
    t.string "email_address", null: false
    t.string "display_name"
    t.string "smtp_host"
    t.integer "smtp_port", default: 587
    t.string "smtp_username"
    t.text "smtp_password_encrypted"
    t.string "smtp_authentication", default: "plain"
    t.boolean "smtp_enable_tls", default: true
    t.boolean "smtp_enable_starttls", default: true
    t.text "oauth_token_encrypted"
    t.text "oauth_refresh_token_encrypted"
    t.datetime "oauth_expires_at"
    t.string "oauth_provider"
    t.boolean "is_default", default: false
    t.boolean "is_active", default: true
    t.datetime "verified_at"
    t.string "verification_token"
    t.datetime "verification_sent_at"
    t.datetime "last_used_at"
    t.datetime "last_error_at"
    t.text "last_error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_location_email_connections_on_company_id"
    t.index ["location_id"], name: "index_location_email_connections_on_location_id", unique: true
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
    t.boolean "is_default", default: false, null: false
    t.jsonb "allowed_form_states", default: [], null: false
    t.boolean "is_corporate", default: false, null: false
    t.index ["active"], name: "index_locations_on_active"
    t.index ["company_id", "active"], name: "index_locations_on_company_id_and_active"
    t.index ["company_id", "code"], name: "index_locations_on_company_id_and_code", unique: true, where: "(code IS NOT NULL)"
    t.index ["company_id", "is_corporate"], name: "index_locations_one_corporate_per_company", unique: true, where: "(is_corporate = true)"
    t.index ["company_id", "is_default"], name: "index_locations_on_company_id_and_is_default"
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
    t.string "code"
    t.string "logo_url"
    t.boolean "scraper_enabled", default: false
    t.jsonb "scraper_config", default: {}
    t.datetime "last_scraped_at"
    t.string "contact_name"
    t.string "claim_email"
    t.string "claim_contact_name"
    t.bigint "company_id"
    t.index ["active", "industry_type"], name: "index_manufacturers_on_active_and_industry_type"
    t.index ["active"], name: "index_manufacturers_on_active"
    t.index ["company_id", "code"], name: "index_manufacturers_on_company_id_and_code", unique: true, where: "(code IS NOT NULL)"
    t.index ["company_id"], name: "index_manufacturers_on_company_id"
    t.index ["industry_type"], name: "index_manufacturers_on_industry_type"
    t.index ["name"], name: "index_manufacturers_on_name"
    t.index ["scraper_enabled"], name: "index_manufacturers_on_scraper_enabled"
  end

  create_table "marketing_content", force: :cascade do |t|
    t.bigint "knowledge_module_id"
    t.bigint "knowledge_feature_id"
    t.string "content_type", null: false
    t.string "title", null: false
    t.text "content"
    t.string "status", default: "draft", null: false
    t.datetime "published_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["content_type"], name: "index_marketing_content_on_content_type"
    t.index ["knowledge_feature_id"], name: "index_marketing_content_on_knowledge_feature_id"
    t.index ["knowledge_module_id"], name: "index_marketing_content_on_knowledge_module_id"
    t.index ["published_at"], name: "index_marketing_content_on_published_at"
    t.index ["status"], name: "index_marketing_content_on_status"
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
    t.string "category", default: "general", null: false
    t.string "author_type", default: "staff", null: false
    t.index ["created_at"], name: "index_notes_on_created_at"
    t.index ["entity_type", "entity_id", "category"], name: "index_notes_on_entity_and_category"
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
    t.jsonb "context", default: {}
    t.index ["company_id"], name: "index_nurture_enrollments_on_company_id"
    t.index ["enrollable_type", "enrollable_id"], name: "index_nurture_enrollments_on_enrollable_type_and_enrollable_id"
    t.index ["lead_id", "nurture_sequence_id"], name: "idx_unique_active_enrollment", unique: true, where: "((status)::text = ANY (ARRAY[('running'::character varying)::text, ('paused'::character varying)::text]))"
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
    t.string "channel", default: "email"
    t.jsonb "attachments", default: []
    t.boolean "include_inventory", default: false
    t.string "inventory_display_mode", default: "auto"
    t.index ["nurture_sequence_id", "position"], name: "index_nurture_steps_on_nurture_sequence_id_and_position"
    t.index ["nurture_sequence_id"], name: "index_nurture_steps_on_nurture_sequence_id"
    t.index ["template_id"], name: "index_nurture_steps_on_template_id"
  end

  create_table "offline_sync_logs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id", null: false
    t.string "device_id"
    t.string "sync_status", default: "pending"
    t.integer "total_operations", default: 0
    t.integer "successful_operations", default: 0
    t.integer "failed_operations", default: 0
    t.jsonb "operations", default: []
    t.jsonb "errors", default: []
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "user_id"], name: "index_offline_sync_logs_on_company_id_and_user_id"
    t.index ["company_id"], name: "index_offline_sync_logs_on_company_id"
    t.index ["device_id"], name: "index_offline_sync_logs_on_device_id"
    t.index ["user_id"], name: "index_offline_sync_logs_on_user_id"
  end

  create_table "option_categories", force: :cascade do |t|
    t.bigint "floor_plan_id"
    t.string "name", null: false
    t.text "description"
    t.integer "display_order", default: 0
    t.boolean "is_required", default: false, null: false
    t.boolean "allow_multiple_selections", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "scope", default: "factory", null: false
    t.string "category_key"
    t.string "series"
    t.bigint "factory_id"
    t.index ["category_key"], name: "index_option_categories_on_category_key"
    t.index ["factory_id", "category_key"], name: "index_option_categories_on_factory_id_and_category_key"
    t.index ["factory_id"], name: "index_option_categories_on_factory_id"
    t.index ["floor_plan_id", "display_order"], name: "index_option_categories_on_floor_plan_id_and_display_order"
    t.index ["floor_plan_id"], name: "index_option_categories_on_floor_plan_id"
    t.index ["scope"], name: "index_option_categories_on_scope"
  end

  create_table "package_templates", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.text "description"
    t.decimal "default_price", precision: 12, scale: 2, default: "0.0"
    t.boolean "include_in_total", default: true, null: false
    t.integer "position", default: 0, null: false
    t.boolean "is_active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "applicable_to", default: "all", null: false
    t.boolean "taxable", default: false
    t.decimal "tax_rate", precision: 5, scale: 3
    t.decimal "cost", precision: 12, scale: 2
    t.string "visibility_scope", default: "all"
    t.boolean "show_price_in_marketing", default: true
    t.index ["company_id", "applicable_to"], name: "index_package_templates_on_company_id_and_applicable_to"
    t.index ["company_id", "is_active"], name: "index_package_templates_on_company_id_and_is_active"
    t.index ["company_id", "position"], name: "index_package_templates_on_company_id_and_position"
    t.index ["company_id"], name: "index_package_templates_on_company_id"
  end

  create_table "page_layouts", force: :cascade do |t|
    t.integer "company_id", null: false
    t.string "module_name", null: false
    t.string "layout_type", default: "detail", null: false
    t.jsonb "layout_data", default: {}, null: false
    t.boolean "is_default", default: false
    t.bigint "created_by_id"
    t.bigint "updated_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "module_name", "layout_type"], name: "idx_page_layouts_company_module_type", unique: true
    t.index ["company_id"], name: "index_page_layouts_on_company_id"
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
    t.jsonb "images", default: []
    t.bigint "factory_id"
    t.bigint "floor_plan_id"
    t.boolean "is_configured_home", default: false
    t.string "vin"
    t.string "serial_number"
    t.index ["barcode"], name: "index_parts_on_barcode"
    t.index ["category_id"], name: "index_parts_on_category_id"
    t.index ["company_id", "active"], name: "index_parts_on_company_id_and_active"
    t.index ["company_id", "category_id"], name: "index_parts_on_company_id_and_category_id"
    t.index ["company_id", "name"], name: "index_parts_on_company_id_and_name", where: "(is_deleted = false)"
    t.index ["company_id", "sku"], name: "index_parts_on_company_id_and_sku", unique: true, where: "(is_deleted = false)"
    t.index ["company_id"], name: "index_parts_on_company_id"
    t.index ["created_by_id"], name: "index_parts_on_created_by_id"
    t.index ["factory_id"], name: "index_parts_on_factory_id"
    t.index ["floor_plan_id", "active"], name: "idx_parts_floor_plan_active"
    t.index ["floor_plan_id"], name: "index_parts_on_floor_plan_id"
    t.index ["images"], name: "index_parts_on_images", using: :gin
    t.index ["is_configured_home"], name: "index_parts_on_is_configured_home"
    t.index ["manufacturer_id"], name: "index_parts_on_manufacturer_id"
    t.index ["manufacturer_part_no"], name: "index_parts_on_manufacturer_part_no"
    t.index ["qb_item_id"], name: "index_parts_on_qb_item_id"
    t.index ["serial_number"], name: "index_parts_on_serial_number", where: "(serial_number IS NOT NULL)"
    t.index ["updated_by_id"], name: "index_parts_on_updated_by_id"
    t.index ["vin"], name: "index_parts_on_vin", where: "(vin IS NOT NULL)"
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

  create_table "pending_import_links", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "entity_type", null: false
    t.bigint "entity_id", null: false
    t.string "target_column", null: false
    t.string "parent_model", null: false
    t.jsonb "match_fields", default: [], null: false
    t.string "lookup_value", null: false
    t.string "lookup_key"
    t.string "status", default: "pending", null: false
    t.datetime "resolved_at"
    t.bigint "resolved_parent_id"
    t.bigint "import_job_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "parent_model", "status"], name: "idx_pending_links_resolution"
    t.index ["company_id", "status", "lookup_value"], name: "idx_pending_links_value"
    t.index ["company_id"], name: "index_pending_import_links_on_company_id"
    t.index ["entity_type", "entity_id"], name: "idx_pending_links_entity"
    t.index ["import_job_id"], name: "index_pending_import_links_on_import_job_id"
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

  create_table "printed_checks", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "bank_account_id", null: false
    t.bigint "journal_entry_id"
    t.string "status", default: "queued"
    t.string "paid_to", null: false
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.string "check_number"
    t.string "memo"
    t.string "description"
    t.date "printed_on"
    t.bigint "contact_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "vendor_id"
    t.bigint "bill_id"
    t.bigint "bill_payment_id"
    t.index ["bank_account_id", "check_number"], name: "index_printed_checks_on_bank_account_id_and_check_number", unique: true, where: "(check_number IS NOT NULL)"
    t.index ["bank_account_id"], name: "index_printed_checks_on_bank_account_id"
    t.index ["bill_id"], name: "index_printed_checks_on_bill_id"
    t.index ["bill_payment_id"], name: "index_printed_checks_on_bill_payment_id"
    t.index ["company_id", "status"], name: "index_printed_checks_on_company_id_and_status"
    t.index ["company_id"], name: "index_printed_checks_on_company_id"
    t.index ["contact_id"], name: "index_printed_checks_on_contact_id"
    t.index ["journal_entry_id"], name: "index_printed_checks_on_journal_entry_id"
    t.index ["vendor_id"], name: "index_printed_checks_on_vendor_id"
  end

  create_table "project_cost_items", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "project_id", null: false
    t.bigint "project_phase_id"
    t.bigint "project_task_id"
    t.string "cost_type", null: false
    t.string "category"
    t.string "description", null: false
    t.string "vendor_name"
    t.string "invoice_number"
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.decimal "quantity", precision: 10, scale: 2, default: "1.0"
    t.decimal "unit_price", precision: 12, scale: 2
    t.date "date"
    t.string "status", default: "pending"
    t.datetime "paid_at"
    t.bigint "approved_by_id"
    t.text "notes"
    t.string "receipt_url"
    t.string "receipt_s3_key"
    t.bigint "part_id"
    t.bigint "inventory_transaction_id"
    t.boolean "is_deleted", default: false
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "vendor_id"
    t.index ["approved_by_id"], name: "index_project_cost_items_on_approved_by_id"
    t.index ["company_id"], name: "index_project_cost_items_on_company_id"
    t.index ["cost_type"], name: "index_project_cost_items_on_cost_type"
    t.index ["date"], name: "index_project_cost_items_on_date"
    t.index ["inventory_transaction_id"], name: "index_project_cost_items_on_inventory_transaction_id"
    t.index ["part_id"], name: "index_project_cost_items_on_part_id"
    t.index ["project_id"], name: "index_project_cost_items_on_project_id"
    t.index ["project_phase_id"], name: "index_project_cost_items_on_project_phase_id"
    t.index ["project_task_id"], name: "index_project_cost_items_on_project_task_id"
    t.index ["status"], name: "index_project_cost_items_on_status"
    t.index ["vendor_id"], name: "index_project_cost_items_on_vendor_id"
  end

  create_table "project_documents", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "project_id", null: false
    t.string "documentable_type"
    t.bigint "documentable_id"
    t.bigint "uploaded_by_id"
    t.string "title", null: false
    t.text "description"
    t.string "category", null: false
    t.string "file_url", null: false
    t.string "file_s3_key", null: false
    t.string "file_name", null: false
    t.integer "file_size"
    t.string "content_type"
    t.boolean "is_deleted", default: false
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_project_documents_on_category"
    t.index ["company_id"], name: "index_project_documents_on_company_id"
    t.index ["documentable_type", "documentable_id"], name: "index_project_documents_on_documentable"
    t.index ["project_id"], name: "index_project_documents_on_project_id"
    t.index ["uploaded_by_id"], name: "index_project_documents_on_uploaded_by_id"
  end

  create_table "project_material_usages", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "project_id", null: false
    t.bigint "project_phase_id"
    t.bigint "project_task_id"
    t.bigint "part_id", null: false
    t.bigint "location_id", null: false
    t.bigint "bin_id"
    t.decimal "quantity_allocated", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "quantity_checked_out", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "quantity_used", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "quantity_returned", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "unit_cost", precision: 12, scale: 2
    t.string "status", default: "allocated"
    t.datetime "checked_out_at"
    t.bigint "checked_out_by_id"
    t.datetime "used_at"
    t.bigint "used_by_id"
    t.datetime "returned_at"
    t.bigint "returned_by_id"
    t.text "notes"
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bin_id"], name: "index_project_material_usages_on_bin_id"
    t.index ["checked_out_by_id"], name: "index_project_material_usages_on_checked_out_by_id"
    t.index ["company_id"], name: "index_project_material_usages_on_company_id"
    t.index ["location_id"], name: "index_project_material_usages_on_location_id"
    t.index ["part_id"], name: "index_project_material_usages_on_part_id"
    t.index ["project_id"], name: "index_project_material_usages_on_project_id"
    t.index ["project_phase_id"], name: "index_project_material_usages_on_project_phase_id"
    t.index ["project_task_id"], name: "index_project_material_usages_on_project_task_id"
    t.index ["returned_by_id"], name: "index_project_material_usages_on_returned_by_id"
    t.index ["status"], name: "index_project_material_usages_on_status"
    t.index ["used_by_id"], name: "index_project_material_usages_on_used_by_id"
  end

  create_table "project_notification_preferences", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.bigint "company_id", null: false
    t.string "recipient_type", null: false
    t.bigint "recipient_id", null: false
    t.string "recipient_email"
    t.string "recipient_phone"
    t.boolean "notify_phase_started", default: true
    t.boolean "notify_phase_completed", default: true
    t.boolean "notify_task_assigned", default: true
    t.boolean "notify_task_completed", default: false
    t.boolean "notify_inspection_scheduled", default: true
    t.boolean "notify_inspection_passed", default: true
    t.boolean "notify_inspection_failed", default: true
    t.boolean "notify_milestone_reached", default: true
    t.boolean "notify_payment_due", default: true
    t.boolean "notify_daily_summary", default: false
    t.boolean "via_email", default: true
    t.boolean "via_sms", default: false
    t.boolean "is_active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_project_notification_preferences_on_company_id"
    t.index ["project_id", "recipient_type", "recipient_id"], name: "idx_proj_notif_prefs_unique", unique: true
    t.index ["project_id"], name: "index_project_notification_preferences_on_project_id"
  end

  create_table "project_phase_tasks", force: :cascade do |t|
    t.bigint "project_phase_id", null: false
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.boolean "is_required", default: false
    t.datetime "completed_at"
    t.bigint "completed_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "assigned_to_id"
    t.boolean "visible_to_client", default: false, null: false
    t.boolean "client_actionable", default: false, null: false
    t.datetime "client_acknowledged_at"
    t.string "client_acknowledged_by"
    t.integer "estimated_days"
    t.date "estimated_start_date"
    t.date "estimated_completion_date"
    t.index ["assigned_to_id"], name: "index_project_phase_tasks_on_assigned_to_id"
    t.index ["company_id"], name: "index_project_phase_tasks_on_company_id"
    t.index ["completed_by_id"], name: "index_project_phase_tasks_on_completed_by_id"
    t.index ["project_phase_id", "position"], name: "idx_project_phase_tasks_phase_position"
    t.index ["project_phase_id"], name: "index_project_phase_tasks_on_project_phase_id"
  end

  create_table "project_phases", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.text "description"
    t.integer "position", default: 0, null: false
    t.string "status", default: "not_started", null: false
    t.boolean "is_required", default: true
    t.datetime "started_at"
    t.datetime "completed_at"
    t.date "estimated_start_date"
    t.date "estimated_completion_date"
    t.integer "estimated_days"
    t.boolean "visible_to_client", default: true
    t.boolean "notify_client_on_start", default: false
    t.boolean "notify_client_on_complete", default: true
    t.boolean "client_notified_start", default: false
    t.boolean "client_notified_complete", default: false
    t.text "notes"
    t.text "client_notes"
    t.string "icon"
    t.string "color"
    t.bigint "completed_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "estimated_budget", precision: 12, scale: 2
    t.decimal "actual_cost", precision: 12, scale: 2, default: "0.0"
    t.index ["company_id", "status"], name: "idx_project_phases_company_status"
    t.index ["company_id"], name: "index_project_phases_on_company_id"
    t.index ["project_id", "position"], name: "idx_project_phases_project_position"
    t.index ["project_id", "status"], name: "idx_project_phases_project_status"
    t.index ["project_id"], name: "index_project_phases_on_project_id"
    t.index ["status"], name: "idx_project_phases_status"
  end

  create_table "project_task_checklist_items", force: :cascade do |t|
    t.bigint "project_task_checklist_id", null: false
    t.string "title", null: false
    t.boolean "completed", default: false
    t.integer "position", default: 0
    t.bigint "completed_by_id"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["completed_by_id"], name: "index_project_task_checklist_items_on_completed_by_id"
    t.index ["project_task_checklist_id", "position"], name: "idx_checklist_items_on_checklist_and_position"
    t.index ["project_task_checklist_id"], name: "idx_on_project_task_checklist_id_23434b401a"
  end

  create_table "project_task_checklists", force: :cascade do |t|
    t.bigint "project_task_id", null: false
    t.string "title", null: false
    t.integer "position", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_task_id", "position"], name: "index_project_task_checklists_on_project_task_id_and_position"
    t.index ["project_task_id"], name: "index_project_task_checklists_on_project_task_id"
  end

  create_table "project_task_dependencies", force: :cascade do |t|
    t.bigint "task_id", null: false
    t.bigint "depends_on_id", null: false
    t.string "dependency_type", default: "finish_to_start"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["depends_on_id"], name: "index_project_task_dependencies_on_depends_on_id"
    t.index ["task_id", "depends_on_id"], name: "idx_task_deps_unique", unique: true
    t.index ["task_id"], name: "index_project_task_dependencies_on_task_id"
  end

  create_table "project_tasks", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "project_id", null: false
    t.bigint "project_phase_id", null: false
    t.bigint "assigned_to_id"
    t.string "title", null: false
    t.text "description"
    t.string "status", default: "pending"
    t.string "priority", default: "medium"
    t.integer "position", default: 0
    t.date "due_date"
    t.date "started_at"
    t.date "completed_at"
    t.decimal "estimated_hours", precision: 8, scale: 2
    t.decimal "actual_hours", precision: 8, scale: 2
    t.decimal "estimated_cost", precision: 10, scale: 2
    t.decimal "actual_cost", precision: 10, scale: 2
    t.string "task_type"
    t.boolean "is_deleted", default: false
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["assigned_to_id"], name: "index_project_tasks_on_assigned_to_id"
    t.index ["company_id", "is_deleted"], name: "index_project_tasks_on_company_id_and_is_deleted"
    t.index ["company_id"], name: "index_project_tasks_on_company_id"
    t.index ["project_id", "status"], name: "index_project_tasks_on_project_id_and_status"
    t.index ["project_id"], name: "index_project_tasks_on_project_id"
    t.index ["project_phase_id", "position"], name: "index_project_tasks_on_project_phase_id_and_position"
    t.index ["project_phase_id"], name: "index_project_tasks_on_project_phase_id"
  end

  create_table "project_template_phase_tasks", force: :cascade do |t|
    t.bigint "project_template_phase_id", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.boolean "is_required", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "visible_to_client", default: false, null: false
    t.boolean "client_actionable", default: false, null: false
    t.integer "estimated_days"
    t.index ["project_template_phase_id", "position"], name: "idx_template_phase_tasks_phase_position"
    t.index ["project_template_phase_id"], name: "idx_on_project_template_phase_id_9658b0b17b"
  end

  create_table "project_template_phases", force: :cascade do |t|
    t.bigint "project_template_id", null: false
    t.string "name", null: false
    t.text "description"
    t.integer "position", default: 0, null: false
    t.boolean "visible_to_client", default: true
    t.boolean "is_required", default: true
    t.boolean "notify_client_on_start", default: false
    t.boolean "notify_client_on_complete", default: true
    t.integer "estimated_days"
    t.string "icon"
    t.string "color"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "default_tasks", default: []
    t.index ["project_template_id", "position"], name: "idx_template_phases_template_position"
    t.index ["project_template_id"], name: "index_project_template_phases_on_project_template_id"
  end

  create_table "project_templates", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "name", null: false
    t.text "description"
    t.string "template_type", default: "standard"
    t.boolean "is_default", default: false
    t.boolean "is_active", default: true
    t.boolean "is_deleted", default: false
    t.integer "phase_count", default: 0
    t.bigint "created_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "is_active"], name: "idx_project_templates_company_active"
    t.index ["company_id", "is_default"], name: "idx_project_templates_company_default"
    t.index ["company_id", "template_type"], name: "idx_project_templates_company_type"
    t.index ["company_id"], name: "index_project_templates_on_company_id"
    t.index ["location_id"], name: "index_project_templates_on_location_id"
  end

  create_table "projects", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.bigint "deal_id"
    t.bigint "project_template_id"
    t.string "name", null: false
    t.string "project_number"
    t.text "description"
    t.string "status", default: "active", null: false
    t.bigint "current_phase_id"
    t.integer "phase_count", default: 0
    t.integer "completed_phase_count", default: 0
    t.integer "progress_percent", default: 0
    t.date "started_at"
    t.date "estimated_completion_date"
    t.date "actual_completion_date"
    t.string "customer_name"
    t.string "customer_email"
    t.string "customer_phone"
    t.string "home_make"
    t.string "home_model"
    t.string "home_serial_number"
    t.bigint "vehicle_id"
    t.string "delivery_street"
    t.string "delivery_city"
    t.string "delivery_state"
    t.string "delivery_zip"
    t.bigint "owner_id"
    t.bigint "created_by_id"
    t.boolean "client_visible", default: true
    t.string "client_access_token"
    t.boolean "is_deleted", default: false
    t.jsonb "custom_field_values", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "budget_amount", precision: 12, scale: 2
    t.decimal "actual_cost", precision: 12, scale: 2, default: "0.0"
    t.decimal "labor_cost", precision: 12, scale: 2, default: "0.0"
    t.decimal "materials_cost", precision: 12, scale: 2, default: "0.0"
    t.decimal "subcontractor_cost", precision: 12, scale: 2, default: "0.0"
    t.decimal "other_cost", precision: 12, scale: 2, default: "0.0"
    t.bigint "land_parcel_id"
    t.index ["client_access_token"], name: "idx_projects_client_token", unique: true
    t.index ["company_id", "location_id"], name: "idx_projects_company_location"
    t.index ["company_id", "project_number"], name: "idx_projects_company_number", unique: true
    t.index ["company_id", "status"], name: "idx_projects_company_status"
    t.index ["company_id"], name: "index_projects_on_company_id"
    t.index ["current_phase_id"], name: "idx_projects_current_phase"
    t.index ["custom_field_values"], name: "idx_projects_custom_fields", using: :gin
    t.index ["deal_id"], name: "idx_projects_deal"
    t.index ["deal_id"], name: "index_projects_on_deal_id"
    t.index ["is_deleted"], name: "idx_projects_deleted"
    t.index ["land_parcel_id"], name: "index_projects_on_land_parcel_id"
    t.index ["location_id"], name: "index_projects_on_location_id"
    t.index ["owner_id"], name: "idx_projects_owner"
    t.index ["project_template_id"], name: "index_projects_on_project_template_id"
    t.index ["status"], name: "idx_projects_status"
    t.index ["vehicle_id"], name: "idx_projects_vehicle"
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
    t.datetime "received_date"
    t.bigint "vendor_id"
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
    t.index ["received_date"], name: "index_purchase_orders_on_received_date"
    t.index ["status"], name: "index_purchase_orders_on_status"
    t.index ["supplier_id"], name: "index_purchase_orders_on_supplier_id"
    t.index ["vendor_id"], name: "index_purchase_orders_on_vendor_id"
  end

  create_table "quickbooks_connections", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "realm_id"
    t.string "company_name"
    t.text "access_token"
    t.text "refresh_token"
    t.datetime "token_expires_at"
    t.datetime "refresh_token_expires_at"
    t.string "status", default: "disconnected"
    t.text "error_message"
    t.boolean "sync_enabled", default: false
    t.boolean "auto_sync_enabled", default: false
    t.string "auto_sync_interval", default: "daily"
    t.date "sync_start_date"
    t.boolean "initial_sync_complete", default: false
    t.string "sync_mode", default: "create_only"
    t.datetime "last_sync_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "idx_qbo_connections_company_unique", unique: true
    t.index ["company_id"], name: "index_quickbooks_connections_on_company_id"
  end

  create_table "quickbooks_entity_mappings", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "entity_type", null: false
    t.bigint "ri_entity_id", null: false
    t.string "qb_entity_type", null: false
    t.string "qb_entity_id", null: false
    t.string "sync_status", default: "synced"
    t.text "error_message"
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "entity_type", "ri_entity_id"], name: "idx_qb_entity_mappings_unique", unique: true
    t.index ["company_id", "qb_entity_type", "qb_entity_id"], name: "idx_qb_entity_mappings_qb"
    t.index ["company_id"], name: "index_quickbooks_entity_mappings_on_company_id"
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
    t.integer "deal_id"
    t.text "terms"
    t.decimal "tax_rate", precision: 5, scale: 2, default: "0.0"
    t.integer "sales_rep_id"
    t.string "pricing_display", default: "detailed"
    t.jsonb "draw_schedule", default: {}
    t.string "billing_street"
    t.string "billing_city"
    t.string "billing_state"
    t.string "billing_zip"
    t.string "billing_country"
    t.string "delivery_street"
    t.string "delivery_city"
    t.string "delivery_state"
    t.string "delivery_zip"
    t.string "delivery_country"
    t.jsonb "custom_field_values", default: {}, null: false
    t.index ["account_id"], name: "index_quotes_on_account_id"
    t.index ["company_id", "location_id"], name: "index_quotes_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_quotes_on_company_id"
    t.index ["contact_id"], name: "index_quotes_on_contact_id"
    t.index ["created_at"], name: "index_quotes_on_created_at"
    t.index ["customer_id"], name: "index_quotes_on_customer_id"
    t.index ["deal_id"], name: "index_quotes_on_deal_id"
    t.index ["is_deleted"], name: "index_quotes_on_is_deleted"
    t.index ["location_id"], name: "index_quotes_on_location_id"
    t.index ["public_token"], name: "index_quotes_on_public_token", unique: true
    t.index ["quote_number"], name: "index_quotes_on_quote_number", unique: true
    t.index ["sales_rep_id"], name: "index_quotes_on_sales_rep_id"
    t.index ["status"], name: "index_quotes_on_status"
    t.index ["valid_until"], name: "index_quotes_on_valid_until"
    t.index ["vehicle_id"], name: "index_quotes_on_vehicle_id"
  end

  create_table "recurring_bills", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.bigint "supplier_id"
    t.bigint "contact_id"
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.string "frequency", null: false
    t.date "next_due_date", null: false
    t.date "end_date"
    t.bigint "expense_account_id", null: false
    t.bigint "payment_account_id"
    t.string "posting_type", default: "ap"
    t.boolean "auto_post", default: false
    t.boolean "is_active", default: true
    t.string "memo"
    t.string "invoice_number_pattern"
    t.bigint "location_id"
    t.string "department"
    t.datetime "last_generated_at"
    t.integer "generated_count", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "vendor_id"
    t.index ["company_id", "is_active"], name: "index_recurring_bills_on_company_id_and_is_active"
    t.index ["company_id"], name: "index_recurring_bills_on_company_id"
    t.index ["contact_id"], name: "index_recurring_bills_on_contact_id"
    t.index ["expense_account_id"], name: "index_recurring_bills_on_expense_account_id"
    t.index ["location_id"], name: "index_recurring_bills_on_location_id"
    t.index ["next_due_date"], name: "index_recurring_bills_on_next_due_date"
    t.index ["payment_account_id"], name: "index_recurring_bills_on_payment_account_id"
    t.index ["supplier_id"], name: "index_recurring_bills_on_supplier_id"
    t.index ["vendor_id"], name: "index_recurring_bills_on_vendor_id"
  end

  create_table "recurring_journal_entries", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.string "frequency", null: false
    t.date "next_run_date"
    t.date "end_date"
    t.jsonb "template_lines", default: []
    t.boolean "auto_post", default: false
    t.boolean "is_active", default: true
    t.datetime "last_run_at"
    t.text "memo"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "is_active"], name: "index_recurring_journal_entries_on_company_id_and_is_active"
    t.index ["company_id"], name: "index_recurring_journal_entries_on_company_id"
    t.index ["next_run_date"], name: "index_recurring_journal_entries_on_next_run_date"
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

  create_table "reports", force: :cascade do |t|
    t.string "name"
    t.text "description"
    t.string "module_key"
    t.jsonb "config"
    t.string "status"
    t.integer "company_id"
    t.integer "user_id"
    t.integer "location_id"
    t.boolean "is_favorite"
    t.boolean "is_deleted"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "visibility"
    t.jsonb "shared_user_ids", default: []
    t.index ["company_id", "module_key"], name: "index_reports_on_company_id_and_module_key"
    t.index ["shared_user_ids"], name: "index_reports_on_shared_user_ids", using: :gin
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
    t.integer "display_order", default: 0, null: false
    t.integer "position", default: 0
    t.index ["active"], name: "index_resources_on_active"
    t.index ["category"], name: "index_resources_on_category"
    t.index ["display_order"], name: "index_resources_on_display_order"
    t.index ["key"], name: "index_resources_on_key", unique: true
    t.index ["permission_ui_type"], name: "index_resources_on_permission_ui_type"
    t.index ["position"], name: "index_resources_on_position"
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
    t.string "ticket_number"
    t.bigint "deal_id"
    t.string "factory_po"
    t.index ["account_id"], name: "index_service_tickets_on_account_id"
    t.index ["assigned_to"], name: "index_service_tickets_on_assigned_to"
    t.index ["company_id", "is_warranty_confirmed"], name: "index_service_tickets_on_company_id_and_is_warranty_confirmed"
    t.index ["company_id", "location_id"], name: "index_service_tickets_on_company_id_and_location_id"
    t.index ["company_id", "ticket_number"], name: "index_service_tickets_on_company_id_and_ticket_number"
    t.index ["company_id"], name: "index_service_tickets_on_company_id"
    t.index ["contact_id"], name: "index_service_tickets_on_contact_id"
    t.index ["customer_type", "customer_id"], name: "index_service_tickets_on_customer_type_and_customer_id"
    t.index ["deal_id"], name: "index_service_tickets_on_deal_id"
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
    t.index ["ticket_number"], name: "index_service_tickets_on_ticket_number", unique: true
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

  create_table "sms_reply_tokens", force: :cascade do |t|
    t.string "token", null: false
    t.bigint "company_id", null: false
    t.bigint "communication_id", null: false
    t.bigint "sender_user_id", null: false
    t.string "contact_phone", null: false
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["communication_id"], name: "index_sms_reply_tokens_on_communication_id"
    t.index ["company_id", "sender_user_id"], name: "index_sms_reply_tokens_on_company_id_and_sender_user_id"
    t.index ["company_id"], name: "index_sms_reply_tokens_on_company_id"
    t.index ["token"], name: "index_sms_reply_tokens_on_token", unique: true
  end

  create_table "sms_usage_logs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "billing_period", null: false
    t.string "direction", null: false
    t.string "source", default: "manual", null: false
    t.integer "message_count", default: 1, null: false
    t.decimal "twilio_cost", precision: 10, scale: 6, default: "0.0"
    t.bigint "communication_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["communication_id"], name: "index_sms_usage_logs_on_communication_id"
    t.index ["company_id", "billing_period"], name: "index_sms_usage_logs_on_company_id_and_billing_period"
    t.index ["company_id"], name: "index_sms_usage_logs_on_company_id"
  end

  create_table "social_accounts", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "platform", null: false
    t.string "account_type", null: false
    t.string "external_id", null: false
    t.string "name"
    t.string "page_url"
    t.text "access_token_encrypted"
    t.string "token_type"
    t.datetime "token_expires_at"
    t.string "status", default: "active"
    t.datetime "last_sync_at"
    t.jsonb "metadata", default: {}
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "platform"], name: "index_social_accounts_on_company_id_and_platform"
    t.index ["external_id", "platform"], name: "index_social_accounts_on_external_id_and_platform"
    t.index ["location_id", "platform"], name: "index_social_accounts_on_location_id_and_platform"
  end

  create_table "social_comments", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "social_post_id", null: false
    t.string "external_comment_id", null: false
    t.string "external_post_id"
    t.string "platform"
    t.string "author_name"
    t.string "author_id"
    t.string "author_profile_pic"
    t.text "message"
    t.string "parent_comment_id"
    t.boolean "is_reply", default: false
    t.string "status", default: "active"
    t.boolean "is_from_page", default: false
    t.bigint "replied_by_user_id"
    t.datetime "commented_at"
    t.datetime "read_at"
    t.jsonb "metadata", default: {}
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "read_at"], name: "index_social_comments_on_company_id_and_read_at"
    t.index ["company_id", "social_post_id"], name: "index_social_comments_on_company_id_and_social_post_id"
    t.index ["company_id", "status"], name: "index_social_comments_on_company_id_and_status"
    t.index ["external_comment_id"], name: "index_social_comments_on_external_comment_id", unique: true
    t.index ["external_post_id"], name: "index_social_comments_on_external_post_id"
  end

  create_table "social_post_schedules", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "name", default: "Default Schedule"
    t.string "frequency", null: false
    t.jsonb "preferred_times", default: ["10:00"]
    t.jsonb "preferred_days", default: [1, 3, 5]
    t.boolean "auto_approve", default: false
    t.boolean "require_vehicle", default: true
    t.jsonb "intent_rotation", default: ["new_arrival", "specific_unit", "education", "social_proof", "lifestyle"]
    t.string "platform", default: "facebook"
    t.string "post_type", default: "company_page"
    t.string "tone", default: "friendly"
    t.bigint "intake_form_id"
    t.bigint "notify_user_id"
    t.boolean "active", default: true
    t.datetime "last_generated_at"
    t.datetime "next_scheduled_at"
    t.string "last_intent_used"
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "ends_at"
    t.jsonb "intent_notes", default: {}, null: false
    t.index ["company_id", "active"], name: "index_social_post_schedules_on_company_id_and_active"
  end

  create_table "social_posts", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.bigint "social_account_id"
    t.bigint "created_by_user_id"
    t.bigint "vehicle_id"
    t.string "post_type"
    t.string "intent_category"
    t.string "platform"
    t.string "status"
    t.text "caption"
    t.string "headline"
    t.text "description"
    t.jsonb "image_urls", default: []
    t.string "cta_type"
    t.string "tagged_url"
    t.string "utm_campaign"
    t.string "utm_content"
    t.datetime "scheduled_at"
    t.datetime "published_at"
    t.string "external_post_id"
    t.integer "lead_count", default: 0
    t.integer "deal_count", default: 0
    t.decimal "attributed_revenue", precision: 12, scale: 2, default: "0.0"
    t.integer "reach"
    t.integer "impressions"
    t.integer "engagement_count"
    t.integer "link_clicks"
    t.datetime "metrics_synced_at"
    t.boolean "nurture_approved", default: false
    t.bigint "nurture_sequence_id"
    t.string "ai_generation_version"
    t.jsonb "generation_context", default: {}
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.index ["approved_by_id"], name: "index_social_posts_on_approved_by_id"
    t.index ["company_id", "intent_category"], name: "index_social_posts_on_company_id_and_intent_category"
    t.index ["company_id", "status"], name: "index_social_posts_on_company_id_and_status"
    t.index ["created_by_user_id"], name: "index_social_posts_on_created_by_user_id"
    t.index ["nurture_sequence_id"], name: "index_social_posts_on_nurture_sequence_id"
    t.index ["published_at"], name: "index_social_posts_on_published_at"
    t.index ["vehicle_id"], name: "index_social_posts_on_vehicle_id"
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

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
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
    t.index ["company_id", "created_at"], name: "index_sources_on_company_id_and_created_at"
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
    t.index ["company_id", "part_id", "location_id", "bin_id"], name: "index_stock_balances_on_company_part_location_bin", unique: true, where: "(bin_id IS NOT NULL)"
    t.index ["company_id", "part_id", "location_id"], name: "index_stock_balances_on_company_part_location_null_bin", unique: true, where: "(bin_id IS NULL)"
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
    t.jsonb "config", default: {}
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
    t.integer "max_ai_credits", default: 50, null: false
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
    t.bigint "vendor_id"
    t.index ["company_id", "active"], name: "index_suppliers_on_company_id_and_active"
    t.index ["company_id", "code"], name: "index_suppliers_on_company_id_and_code", unique: true, where: "((code IS NOT NULL) AND (is_deleted = false))"
    t.index ["company_id", "name"], name: "index_suppliers_on_company_id_and_name", where: "(is_deleted = false)"
    t.index ["company_id"], name: "index_suppliers_on_company_id"
    t.index ["created_by_id"], name: "index_suppliers_on_created_by_id"
    t.index ["qb_vendor_id"], name: "index_suppliers_on_qb_vendor_id"
    t.index ["updated_by_id"], name: "index_suppliers_on_updated_by_id"
    t.index ["vendor_id"], name: "index_suppliers_on_vendor_id"
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
    t.bigint "entity_id", null: false
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
    t.string "category", default: "general"
    t.string "source", default: "manual"
    t.index ["category"], name: "index_templates_on_category"
    t.index ["company_id", "category"], name: "index_templates_on_company_id_and_category"
    t.index ["company_id"], name: "index_templates_on_company_id"
    t.index ["source"], name: "index_templates_on_source"
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
    t.jsonb "config", default: {}
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
    t.integer "ai_credits_override"
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

  create_table "tour_steps", force: :cascade do |t|
    t.bigint "tour_id", null: false
    t.integer "position", null: false
    t.string "selector"
    t.string "title"
    t.text "content"
    t.string "placement", default: "bottom", null: false
    t.string "highlight_type", default: "outline", null: false
    t.boolean "click_required", default: false, null: false
    t.boolean "input_required", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "route"
    t.index ["tour_id", "position"], name: "index_tour_steps_on_tour_id_and_position", unique: true
    t.index ["tour_id"], name: "index_tour_steps_on_tour_id"
  end

  create_table "tours", force: :cascade do |t|
    t.bigint "knowledge_module_id"
    t.string "key", null: false
    t.string "name", null: false
    t.text "description"
    t.string "trigger_type", default: "manual", null: false
    t.boolean "is_active", default: true, null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "trigger_route"
    t.index ["is_active", "position"], name: "index_tours_on_is_active_and_position"
    t.index ["key"], name: "index_tours_on_key"
    t.index ["knowledge_module_id", "key"], name: "index_tours_on_knowledge_module_id_and_key", unique: true
    t.index ["knowledge_module_id"], name: "index_tours_on_knowledge_module_id"
    t.index ["trigger_route"], name: "index_tours_on_trigger_route"
  end

  create_table "tracked_link_events", force: :cascade do |t|
    t.bigint "tracked_link_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "clicked_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["clicked_at"], name: "index_tracked_link_events_on_clicked_at"
    t.index ["tracked_link_id"], name: "index_tracked_link_events_on_tracked_link_id"
  end

  create_table "tracked_links", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "communication_id"
    t.string "token", null: false
    t.string "s3_key"
    t.string "filename"
    t.string "content_type"
    t.integer "file_size"
    t.string "entity_type"
    t.bigint "entity_id"
    t.string "source_type"
    t.bigint "source_id"
    t.integer "click_count", default: 0
    t.datetime "first_clicked_at"
    t.datetime "last_clicked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "vehicle_id"
    t.string "link_type", default: "attachment"
    t.string "url"
    t.index ["communication_id"], name: "index_tracked_links_on_communication_id"
    t.index ["company_id"], name: "index_tracked_links_on_company_id"
    t.index ["entity_type", "entity_id", "vehicle_id"], name: "idx_tracked_links_entity_vehicle"
    t.index ["entity_type", "entity_id"], name: "index_tracked_links_on_entity_type_and_entity_id"
    t.index ["source_type", "source_id"], name: "index_tracked_links_on_source_type_and_source_id"
    t.index ["token"], name: "index_tracked_links_on_token", unique: true
    t.index ["vehicle_id"], name: "index_tracked_links_on_vehicle_id"
  end

  create_table "twilio_accounts", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "sub_account_sid"
    t.text "auth_token"
    t.string "phone_number", null: false
    t.string "phone_number_sid", null: false
    t.string "status", default: "provisioning", null: false
    t.datetime "provisioned_at"
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "location_id"
    t.index ["company_id", "location_id"], name: "index_twilio_accounts_on_company_id_and_location_id"
    t.index ["company_id"], name: "index_twilio_accounts_on_company_id"
    t.index ["phone_number"], name: "index_twilio_accounts_on_phone_number", unique: true
    t.index ["status"], name: "index_twilio_accounts_on_status"
  end

  create_table "user_email_connections", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "company_id", null: false
    t.string "provider", default: "smtp", null: false
    t.string "email_address", null: false
    t.string "display_name"
    t.string "smtp_host"
    t.integer "smtp_port", default: 587
    t.string "smtp_username"
    t.text "smtp_password_encrypted"
    t.string "smtp_authentication", default: "plain"
    t.boolean "smtp_enable_tls", default: true
    t.boolean "smtp_enable_starttls", default: true
    t.text "oauth_token_encrypted"
    t.text "oauth_refresh_token_encrypted"
    t.datetime "oauth_expires_at"
    t.string "oauth_provider"
    t.boolean "is_default", default: false
    t.boolean "is_active", default: true
    t.datetime "verified_at"
    t.string "verification_token"
    t.datetime "verification_sent_at"
    t.datetime "last_used_at"
    t.datetime "last_error_at"
    t.text "last_error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "email_address"], name: "idx_user_email_connections_company_email"
    t.index ["company_id"], name: "index_user_email_connections_on_company_id"
    t.index ["email_address"], name: "index_user_email_connections_on_email_address"
    t.index ["user_id", "is_default"], name: "idx_user_email_connections_user_default"
    t.index ["user_id"], name: "idx_user_email_connections_one_default", unique: true, where: "(is_default = true)"
    t.index ["user_id"], name: "index_user_email_connections_on_user_id"
    t.index ["verification_token"], name: "index_user_email_connections_on_verification_token", unique: true, where: "(verification_token IS NOT NULL)"
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

  create_table "user_tour_completions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "tour_id", null: false
    t.datetime "completed_at"
    t.jsonb "steps_completed", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["completed_at"], name: "index_user_tour_completions_on_completed_at"
    t.index ["tour_id"], name: "index_user_tour_completions_on_tour_id"
    t.index ["user_id", "tour_id"], name: "index_user_tour_completions_on_user_id_and_tour_id", unique: true
    t.index ["user_id"], name: "index_user_tour_completions_on_user_id"
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
    t.string "email_username"
    t.string "email_password"
    t.string "smtp_server"
    t.integer "smtp_port", default: 587
    t.string "signature_url"
    t.string "initials_url"
    t.string "typed_signature"
    t.string "typed_initials"
    t.string "signature_font"
    t.string "landing_page", default: "dashboard", null: false
    t.jsonb "workqueue_preferences", default: {}, null: false
    t.string "booking_url"
    t.boolean "daily_digest_enabled", default: true
    t.integer "daily_digest_hour", default: 7
    t.datetime "daily_digest_last_sent_at"
    t.index ["company_id"], name: "index_users_on_company_id"
    t.index ["custom_permissions"], name: "index_users_on_custom_permissions", using: :gin
    t.index ["deleted_at"], name: "index_users_on_deleted_at"
    t.index ["email", "invitation_id"], name: "index_users_on_email_and_invitation_id"
    t.index ["email_username"], name: "index_users_on_email_username"
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

  create_table "vehicle_documents", force: :cascade do |t|
    t.bigint "vehicle_id", null: false
    t.string "title", null: false
    t.string "category", default: "other", null: false
    t.string "visibility", default: "internal", null: false
    t.string "file_url"
    t.string "file_content_type"
    t.bigint "file_size"
    t.bigint "uploaded_by_user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["uploaded_by_user_id"], name: "index_vehicle_documents_on_uploaded_by_user_id"
    t.index ["vehicle_id", "visibility"], name: "index_vehicle_documents_on_vehicle_id_and_visibility"
    t.index ["vehicle_id"], name: "index_vehicle_documents_on_vehicle_id"
    t.index ["visibility"], name: "index_vehicle_documents_on_visibility"
  end

  create_table "vehicle_invoices", force: :cascade do |t|
    t.bigint "vehicle_id", null: false
    t.bigint "company_id", null: false
    t.decimal "gross_invoice", precision: 15, scale: 2
    t.decimal "base_price", precision: 15, scale: 2
    t.decimal "options_total", precision: 15, scale: 2
    t.decimal "material_surcharge", precision: 15, scale: 2
    t.decimal "factory_freight", precision: 15, scale: 2
    t.decimal "sales_allowance", precision: 15, scale: 2
    t.decimal "hud_fees", precision: 15, scale: 2
    t.decimal "state_assoc_fees", precision: 15, scale: 2
    t.decimal "tax_from_invoice", precision: 15, scale: 2
    t.decimal "total_invoice", precision: 15, scale: 2
    t.decimal "nada_base", precision: 15, scale: 2
    t.integer "vep_code"
    t.integer "wind_zone"
    t.string "invoice_number"
    t.date "invoice_date"
    t.string "manufacturer"
    t.bigint "scanned_document_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "trim_out", precision: 15, scale: 2
    t.decimal "ac_from_invoice", precision: 15, scale: 2
    t.index ["company_id"], name: "index_vehicle_invoices_on_company_id"
    t.index ["scanned_document_id"], name: "index_vehicle_invoices_on_scanned_document_id"
    t.index ["vehicle_id"], name: "index_vehicle_invoices_on_vehicle_id", unique: true
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
    t.boolean "use_location_address", default: false
    t.string "public_id"
    t.integer "sections"
    t.json "floor_plan_images", default: [], null: false
    t.jsonb "custom_field_values", default: {}, null: false
    t.boolean "special_discount_enabled", default: false
    t.string "discount_type"
    t.decimal "discount_value", precision: 12, scale: 2
    t.decimal "discounted_price", precision: 12, scale: 2
    t.string "insulation_r_roof", comment: "Roof insulation R-value (e.g. R-28, R-40)"
    t.string "insulation_r_wall", comment: "Wall insulation R-value (e.g. R-11, R-19)"
    t.string "insulation_r_floor", comment: "Floor insulation R-value (e.g. R-11)"
    t.string "floor_joist_size", comment: "Floor joist dimensions (e.g. 2x6, 2x8, 2x10)"
    t.string "electrical_service", comment: "Electrical service rating (e.g. 100 AMP, 200 AMP)"
    t.decimal "modular_conversion_cost", precision: 10, scale: 2, comment: "Cost for modular conversion package"
    t.string "source", default: "manual", null: false
    t.bigint "floor_plan_id"
    t.string "champion_model_id"
    t.jsonb "champion_raw_payload", default: {}, null: false
    t.jsonb "champion_images", default: [], null: false
    t.datetime "champion_last_seen_at"
    t.bigint "cloned_from_id", comment: "For Champion IMS clones: points to the catalog Vehicle this row was cloned from"
    t.decimal "floor_plan_amount", precision: 15, scale: 2
    t.date "floor_plan_start_date"
    t.decimal "floor_plan_accrued_interest", precision: 15, scale: 2, default: "0.0"
    t.integer "days_on_floor_plan", default: 0
    t.date "floor_plan_curtailed_at"
    t.string "floor_plan_lender"
    t.string "matterport_url"
    t.string "champion_pdp_url"
    t.jsonb "elevation_images", default: [], null: false
    t.string "champion_series_name"
    t.string "champion_brand_name"
    t.string "champion_brand_logo_url"
    t.datetime "sold_at"
    t.bigint "sold_via_deal_id"
    t.decimal "reconditioning_cost", precision: 15, scale: 2
    t.index ["body_style"], name: "index_vehicles_on_body_style"
    t.index ["champion_last_seen_at"], name: "index_vehicles_on_champion_last_seen_at"
    t.index ["champion_model_id"], name: "index_vehicles_on_champion_model_id"
    t.index ["cloned_from_id"], name: "index_vehicles_on_cloned_from_id"
    t.index ["company_id", "inventory_id"], name: "index_vehicles_on_company_id_and_inventory_id", unique: true
    t.index ["company_id", "location_id"], name: "index_vehicles_on_company_id_and_location_id"
    t.index ["company_id", "serial_number"], name: "index_vehicles_on_company_id_and_serial_number", unique: true, where: "(serial_number IS NOT NULL)"
    t.index ["company_id", "vin"], name: "index_vehicles_on_company_id_and_vin", unique: true, where: "(vin IS NOT NULL)"
    t.index ["company_id"], name: "index_vehicles_on_company_id"
    t.index ["condition"], name: "index_vehicles_on_condition"
    t.index ["dealer_cost"], name: "index_vehicles_on_dealer_cost"
    t.index ["dwelling_type"], name: "index_vehicles_on_dwelling_type"
    t.index ["exterior_color"], name: "index_vehicles_on_exterior_color"
    t.index ["floor_plan_id"], name: "index_vehicles_on_floor_plan_id"
    t.index ["home_type"], name: "index_vehicles_on_home_type"
    t.index ["is_deleted"], name: "index_vehicles_on_is_deleted"
    t.index ["listing_type"], name: "index_vehicles_on_listing_type"
    t.index ["location_id"], name: "index_vehicles_on_location_id"
    t.index ["mileage", "year"], name: "index_vehicles_on_mileage_and_year"
    t.index ["public_id"], name: "index_vehicles_on_public_id", unique: true
    t.index ["quickbooks_id"], name: "index_vehicles_on_quickbooks_id"
    t.index ["rv_class"], name: "index_vehicles_on_rv_class"
    t.index ["rv_type"], name: "index_vehicles_on_rv_type"
    t.index ["sleeping_capacity"], name: "index_vehicles_on_sleeping_capacity"
    t.index ["slideouts"], name: "index_vehicles_on_slideouts"
    t.index ["sold_via_deal_id"], name: "index_vehicles_on_sold_via_deal_id"
    t.index ["source"], name: "index_vehicles_on_source"
    t.index ["status"], name: "index_vehicles_on_status"
    t.index ["total_cost"], name: "index_vehicles_on_total_cost"
    t.index ["use_location_address"], name: "index_vehicles_on_use_location_address"
    t.index ["year", "make", "model"], name: "index_vehicles_on_year_and_make_and_model"
  end

  create_table "vendors", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.string "contact_name"
    t.string "email"
    t.string "phone"
    t.string "trade_type", default: "general"
    t.string "license_number"
    t.string "license_state"
    t.date "license_expiry"
    t.string "insurance_provider"
    t.string "insurance_policy_number"
    t.date "insurance_expiry"
    t.boolean "bonded", default: false
    t.decimal "bond_amount", precision: 10, scale: 2
    t.date "bond_expiry"
    t.decimal "hourly_rate", precision: 10, scale: 2
    t.text "notes"
    t.string "status", default: "active"
    t.decimal "rating", precision: 3, scale: 2
    t.boolean "is_deleted", default: false
    t.jsonb "custom_field_values", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "portal_access_token"
    t.datetime "portal_token_expires_at"
    t.datetime "last_portal_login_at"
    t.boolean "is_vendor", default: false
    t.string "password_digest"
    t.boolean "password_login_enabled", default: false
    t.string "vendor_type", default: "contractor", null: false
    t.string "code"
    t.string "website"
    t.string "address_line1"
    t.string "address_line2"
    t.string "city"
    t.string "state"
    t.string "zip_code"
    t.string "country", default: "US"
    t.string "tax_id"
    t.string "payment_terms"
    t.integer "default_lead_time_days"
    t.string "qb_vendor_id"
    t.boolean "active", default: true
    t.datetime "deleted_at"
    t.bigint "created_by_id"
    t.bigint "updated_by_id"
    t.string "account_number"
    t.boolean "is_1099_eligible", default: false
    t.bigint "default_expense_account_id"
    t.index ["company_id"], name: "index_vendors_on_company_id"
    t.index ["default_expense_account_id"], name: "index_vendors_on_default_expense_account_id"
    t.index ["email"], name: "index_vendors_on_email"
    t.index ["is_vendor"], name: "index_vendors_on_is_vendor"
    t.index ["portal_access_token"], name: "index_vendors_on_portal_access_token", unique: true
    t.index ["qb_vendor_id"], name: "index_vendors_on_qb_vendor_id"
    t.index ["status"], name: "index_vendors_on_status"
    t.index ["trade_type"], name: "index_vendors_on_trade_type"
    t.index ["vendor_type"], name: "index_vendors_on_vendor_type"
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
    t.jsonb "manufacturer_notes", default: [], null: false
    t.index ["company_id", "claim_number"], name: "index_warranty_claims_on_company_id_and_claim_number", unique: true
    t.index ["company_id", "is_deleted"], name: "index_warranty_claims_on_company_id_and_is_deleted"
    t.index ["company_id", "service_ticket_id"], name: "idx_warranty_claims_one_active_per_ticket", unique: true, where: "(is_deleted = false)"
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

  create_table "webhook_deliveries", force: :cascade do |t|
    t.bigint "webhook_endpoint_id", null: false
    t.string "event", null: false
    t.jsonb "payload", default: {}
    t.integer "response_code"
    t.text "response_body"
    t.datetime "delivered_at"
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["delivered_at"], name: "index_webhook_deliveries_on_delivered_at"
    t.index ["event"], name: "index_webhook_deliveries_on_event"
    t.index ["webhook_endpoint_id", "event"], name: "index_webhook_deliveries_on_webhook_endpoint_id_and_event"
    t.index ["webhook_endpoint_id"], name: "index_webhook_deliveries_on_webhook_endpoint_id"
  end

  create_table "webhook_endpoints", force: :cascade do |t|
    t.bigint "company_id"
    t.string "url", null: false
    t.jsonb "events", default: []
    t.string "secret", null: false
    t.string "status", default: "active", null: false
    t.datetime "last_triggered_at"
    t.integer "failure_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "location_ids"
    t.string "description"
    t.bigint "created_by_user_id"
    t.index ["company_id", "status"], name: "index_webhook_endpoints_on_company_id_and_status"
    t.index ["company_id"], name: "index_webhook_endpoints_on_company_id"
    t.index ["created_by_user_id"], name: "index_webhook_endpoints_on_created_by_user_id"
    t.index ["status"], name: "index_webhook_endpoints_on_status"
  end

  create_table "website_media", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "website_id"
    t.bigint "uploaded_by_id"
    t.string "name", null: false
    t.string "url", null: false
    t.string "mime_type"
    t.bigint "file_size", null: false
    t.integer "width"
    t.integer "height"
    t.string "s3_key"
    t.string "s3_bucket"
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "file_type", default: 3
    t.index ["company_id"], name: "index_website_media_on_company_id"
    t.index ["file_type"], name: "index_website_media_on_file_type"
    t.index ["uploaded_by_id"], name: "index_website_media_on_uploaded_by_id"
    t.index ["website_id"], name: "index_website_media_on_website_id"
  end

  create_table "website_pages", force: :cascade do |t|
    t.bigint "website_id", null: false
    t.string "title", null: false
    t.string "path", null: false
    t.integer "order", default: 0
    t.boolean "is_visible", default: true
    t.jsonb "blocks", default: []
    t.string "seo_title"
    t.text "seo_description"
    t.string "og_image_url"
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "style", default: {}
    t.boolean "show_in_nav", default: true
    t.boolean "show_in_footer", default: true
    t.index ["order"], name: "index_website_pages_on_order"
    t.index ["website_id", "path"], name: "index_website_pages_on_website_id_and_path", unique: true
    t.index ["website_id"], name: "index_website_pages_on_website_id"
  end

  create_table "website_versions", force: :cascade do |t|
    t.bigint "website_id", null: false
    t.bigint "created_by_id", null: false
    t.string "version_name", null: false
    t.jsonb "snapshot", null: false
    t.boolean "is_published_version", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_website_versions_on_created_at"
    t.index ["created_by_id"], name: "index_website_versions_on_created_by_id"
    t.index ["website_id"], name: "index_website_versions_on_website_id"
  end

  create_table "websites", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "location_id"
    t.string "name", null: false
    t.string "slug", null: false
    t.string "domain"
    t.string "subdomain"
    t.integer "status", default: 0, null: false
    t.integer "build_status", default: 0, null: false
    t.integer "client_access_level", default: 3, null: false
    t.jsonb "theme", default: {}
    t.jsonb "nav_config", default: {}
    t.jsonb "brand", default: {}
    t.jsonb "seo_config", default: {}
    t.jsonb "tracking_config", default: {}
    t.string "favicon_url"
    t.datetime "published_at"
    t.string "preview_url"
    t.string "live_url"
    t.string "netlify_site_id"
    t.string "cloudflare_zone_id"
    t.boolean "is_deleted", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "preview_token"
    t.jsonb "site_header", default: {}
    t.jsonb "site_footer", default: {}
    t.index ["company_id", "slug"], name: "index_websites_on_company_id_and_slug", unique: true
    t.index ["company_id"], name: "index_websites_on_company_id"
    t.index ["domain"], name: "index_websites_on_domain", unique: true, where: "(domain IS NOT NULL)"
    t.index ["location_id"], name: "index_websites_on_location_id"
    t.index ["preview_token"], name: "index_websites_on_preview_token", unique: true
    t.index ["subdomain"], name: "index_websites_on_subdomain", unique: true, where: "(subdomain IS NOT NULL)"
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

  create_table "workflow_ai_generations", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "user_id", null: false
    t.bigint "workflow_rule_id"
    t.bigint "parent_generation_id"
    t.bigint "ai_query_log_id"
    t.text "prompt", null: false
    t.jsonb "context_snapshot", default: {}, null: false
    t.jsonb "generated_plan", default: {}, null: false
    t.string "status", default: "generated", null: false
    t.string "model_version"
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_query_log_id"], name: "index_workflow_ai_generations_on_ai_query_log_id"
    t.index ["company_id", "created_at"], name: "index_workflow_ai_generations_on_company_id_and_created_at"
    t.index ["parent_generation_id"], name: "index_workflow_ai_generations_on_parent_generation_id"
    t.index ["user_id"], name: "index_workflow_ai_generations_on_user_id"
    t.index ["workflow_rule_id"], name: "index_workflow_ai_generations_on_workflow_rule_id"
  end

  create_table "workflow_approvals", force: :cascade do |t|
    t.bigint "workflow_run_id", null: false
    t.string "step_id", null: false
    t.bigint "company_id", null: false
    t.string "status", default: "pending", null: false
    t.bigint "approver_user_id"
    t.datetime "approved_at"
    t.text "rejection_reason"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["approver_user_id"], name: "index_workflow_approvals_on_approver_user_id"
    t.index ["company_id"], name: "index_workflow_approvals_on_company_id"
    t.index ["expires_at"], name: "index_workflow_approvals_on_expires_at"
    t.index ["workflow_run_id"], name: "index_workflow_approvals_on_workflow_run_id"
  end

  create_table "workflow_events", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "event_type", null: false
    t.string "entity_type"
    t.bigint "entity_id"
    t.jsonb "payload", default: {}
    t.datetime "dispatched_at"
    t.jsonb "dispatch_error", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "dispatched_at"], name: "index_workflow_events_on_company_id_and_dispatched_at"
    t.index ["company_id"], name: "index_workflow_events_on_company_id"
    t.index ["dispatched_at"], name: "index_workflow_events_on_dispatched_at"
    t.index ["event_type"], name: "index_workflow_events_on_event_type"
  end

  create_table "workflow_inbound_triggers", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "token", null: false
    t.string "name", null: false
    t.bigint "workflow_rule_id", null: false
    t.boolean "active", default: true
    t.datetime "last_triggered_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_workflow_inbound_triggers_on_company_id"
    t.index ["token"], name: "index_workflow_inbound_triggers_on_token", unique: true
    t.index ["workflow_rule_id"], name: "index_workflow_inbound_triggers_on_workflow_rule_id"
  end

  create_table "workflow_rules", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.text "description"
    t.string "entity_type", null: false
    t.string "status", default: "draft", null: false
    t.bigint "workflow_template_id"
    t.jsonb "trigger", default: {}
    t.jsonb "conditions", default: []
    t.jsonb "steps", default: {}
    t.jsonb "parameters", default: {}
    t.integer "version", default: 1
    t.bigint "created_by_user_id"
    t.boolean "is_seeded", default: false
    t.string "halt_on_reply", default: "false"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "status", "entity_type"], name: "index_workflow_rules_on_company_id_and_status_and_entity_type"
    t.index ["company_id"], name: "index_workflow_rules_on_company_id"
    t.index ["created_by_user_id"], name: "index_workflow_rules_on_created_by_user_id"
    t.index ["entity_type"], name: "index_workflow_rules_on_entity_type"
    t.index ["workflow_template_id"], name: "index_workflow_rules_on_workflow_template_id"
  end

  create_table "workflow_run_steps", force: :cascade do |t|
    t.bigint "workflow_run_id", null: false
    t.string "step_id", null: false
    t.string "step_type", null: false
    t.string "status", null: false
    t.jsonb "input", default: {}
    t.jsonb "output", default: {}
    t.jsonb "error", default: {}
    t.integer "duration_ms"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["workflow_run_id"], name: "index_workflow_run_steps_on_workflow_run_id"
  end

  create_table "workflow_runs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "workflow_rule_id", null: false
    t.string "entity_type", null: false
    t.bigint "entity_id", null: false
    t.string "status", default: "pending", null: false
    t.string "current_step_id"
    t.jsonb "variables", default: {}
    t.datetime "wait_until"
    t.string "wait_reason"
    t.bigint "parent_run_id"
    t.jsonb "rule_snapshot", default: {}
    t.datetime "started_at"
    t.datetime "completed_at"
    t.jsonb "error_details", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "status", "wait_until"], name: "index_workflow_runs_on_company_id_and_status_and_wait_until"
    t.index ["company_id"], name: "index_workflow_runs_on_company_id"
    t.index ["entity_type", "entity_id"], name: "index_workflow_runs_on_entity_type_and_entity_id"
    t.index ["parent_run_id"], name: "index_workflow_runs_on_parent_run_id"
    t.index ["wait_until"], name: "index_workflow_runs_on_wait_until"
    t.index ["workflow_rule_id"], name: "index_workflow_runs_on_workflow_rule_id"
  end

  create_table "workflow_subscriptions", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "workflow_rule_id", null: false
    t.string "event_type", null: false
    t.string "entity_type_filter"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "event_type"], name: "index_workflow_subscriptions_on_company_id_and_event_type"
    t.index ["company_id"], name: "index_workflow_subscriptions_on_company_id"
    t.index ["event_type"], name: "index_workflow_subscriptions_on_event_type"
    t.index ["workflow_rule_id"], name: "index_workflow_subscriptions_on_workflow_rule_id"
  end

  create_table "workflow_templates", force: :cascade do |t|
    t.string "key", null: false
    t.string "name", null: false
    t.text "description"
    t.string "category", null: false
    t.string "entity_type", null: false
    t.string "icon"
    t.text "preview_description"
    t.jsonb "required_integrations", default: []
    t.jsonb "trigger", default: {}
    t.jsonb "conditions", default: []
    t.jsonb "steps", default: {}
    t.jsonb "parameters", default: {}
    t.jsonb "parameter_schema", default: []
    t.boolean "is_active", default: true
    t.integer "sort_order", default: 0
    t.integer "version", default: 1
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_workflow_templates_on_category"
    t.index ["is_active"], name: "index_workflow_templates_on_is_active"
    t.index ["key"], name: "index_workflow_templates_on_key", unique: true
  end

  add_foreign_key "account_links", "chart_of_accounts"
  add_foreign_key "account_links", "companies"
  add_foreign_key "accounting_imports", "companies"
  add_foreign_key "accounting_imports", "users"
  add_foreign_key "accounting_settings", "bank_accounts", column: "default_bank_account_id"
  add_foreign_key "accounting_settings", "chart_of_accounts", column: "city_tax_account_id"
  add_foreign_key "accounting_settings", "chart_of_accounts", column: "county_tax_account_id"
  add_foreign_key "accounting_settings", "chart_of_accounts", column: "default_ap_account_id"
  add_foreign_key "accounting_settings", "chart_of_accounts", column: "default_ar_account_id"
  add_foreign_key "accounting_settings", "chart_of_accounts", column: "default_cogs_account_id"
  add_foreign_key "accounting_settings", "chart_of_accounts", column: "default_parts_inventory_account_id"
  add_foreign_key "accounting_settings", "chart_of_accounts", column: "default_sales_revenue_account_id"
  add_foreign_key "accounting_settings", "chart_of_accounts", column: "default_sales_tax_payable_account_id"
  add_foreign_key "accounting_settings", "chart_of_accounts", column: "default_vehicle_inventory_account_id"
  add_foreign_key "accounting_settings", "chart_of_accounts", column: "retained_earnings_account_id"
  add_foreign_key "accounting_settings", "chart_of_accounts", column: "state_tax_account_id"
  add_foreign_key "accounting_settings", "companies"
  add_foreign_key "accounts", "accounts", column: "parent_account_id"
  add_foreign_key "accounts", "companies"
  add_foreign_key "accounts", "locations"
  add_foreign_key "accounts", "sources"
  add_foreign_key "accounts", "users", column: "owner_id"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "activities", "leads"
  add_foreign_key "activities", "users"
  add_foreign_key "activity_logs", "companies"
  add_foreign_key "agreement_attachments", "agreements"
  add_foreign_key "agreement_audit_logs", "agreement_signers"
  add_foreign_key "agreement_audit_logs", "agreements"
  add_foreign_key "agreement_categories", "companies"
  add_foreign_key "agreement_reminders", "agreement_signers"
  add_foreign_key "agreement_reminders", "agreements"
  add_foreign_key "agreement_signers", "agreements"
  add_foreign_key "agreement_templates", "agreement_categories"
  add_foreign_key "agreement_templates", "companies"
  add_foreign_key "agreement_templates", "locations"
  add_foreign_key "agreements", "agreement_templates"
  add_foreign_key "agreements", "companies"
  add_foreign_key "agreements", "locations"
  add_foreign_key "ai_insights", "leads"
  add_foreign_key "api_logs", "companies"
  add_foreign_key "approval_actions", "approval_steps"
  add_foreign_key "approval_actions", "users"
  add_foreign_key "approval_steps", "approval_workflows"
  add_foreign_key "approval_steps", "users", column: "approver_user_id"
  add_foreign_key "approval_workflows", "deals"
  add_foreign_key "approval_workflows", "users", column: "approved_by_id"
  add_foreign_key "approval_workflows", "users", column: "requested_by_id"
  add_foreign_key "assignment_work_logs", "contractor_assignments"
  add_foreign_key "assignment_work_logs", "vendors", on_delete: :nullify
  add_foreign_key "audience_ai_generations", "ai_query_logs"
  add_foreign_key "audience_ai_generations", "audience_ai_generations", column: "parent_generation_id"
  add_foreign_key "audience_ai_generations", "audiences"
  add_foreign_key "audience_ai_generations", "companies"
  add_foreign_key "audience_ai_generations", "users"
  add_foreign_key "audiences", "audience_ai_generations", column: "generated_from_ai_generation_id"
  add_foreign_key "audiences", "companies"
  add_foreign_key "audiences", "locations"
  add_foreign_key "audiences", "users", column: "created_by_user_id"
  add_foreign_key "bank_accounts", "chart_of_accounts"
  add_foreign_key "bank_accounts", "companies"
  add_foreign_key "bank_accounts", "locations"
  add_foreign_key "bank_reconciliation_items", "bank_reconciliations"
  add_foreign_key "bank_reconciliation_items", "journal_entry_lines"
  add_foreign_key "bank_reconciliations", "bank_accounts"
  add_foreign_key "bank_reconciliations", "companies"
  add_foreign_key "bank_reconciliations", "users", column: "completed_by_id"
  add_foreign_key "bank_rules", "bank_accounts"
  add_foreign_key "bank_rules", "chart_of_accounts", column: "assign_account_id"
  add_foreign_key "bank_rules", "companies"
  add_foreign_key "bank_rules", "contacts", column: "assign_contact_id"
  add_foreign_key "bank_transactions", "bank_accounts"
  add_foreign_key "bank_transactions", "bank_rules", column: "rule_id"
  add_foreign_key "bank_transactions", "chart_of_accounts", column: "category_account_id"
  add_foreign_key "bank_transactions", "companies"
  add_foreign_key "bank_transactions", "contacts"
  add_foreign_key "bank_transactions", "journal_entries", column: "matched_journal_entry_id"
  add_foreign_key "bill_line_items", "bills"
  add_foreign_key "bill_line_items", "chart_of_accounts"
  add_foreign_key "bill_line_items", "locations"
  add_foreign_key "bill_payments", "bank_accounts"
  add_foreign_key "bill_payments", "bills"
  add_foreign_key "bill_payments", "chart_of_accounts"
  add_foreign_key "bill_payments", "companies"
  add_foreign_key "bill_payments", "journal_entries"
  add_foreign_key "bill_payments", "users", column: "created_by_id"
  add_foreign_key "bills", "chart_of_accounts", column: "ap_account_id"
  add_foreign_key "bills", "companies"
  add_foreign_key "bills", "contacts"
  add_foreign_key "bills", "journal_entries"
  add_foreign_key "bills", "journal_entries", column: "payment_journal_entry_id"
  add_foreign_key "bills", "locations"
  add_foreign_key "bills", "users", column: "created_by_id"
  add_foreign_key "bills", "vendors", on_delete: :nullify
  add_foreign_key "bins", "locations"
  add_foreign_key "blog_categories", "websites"
  add_foreign_key "blog_posts", "users", column: "author_id"
  add_foreign_key "blog_posts", "websites"
  add_foreign_key "blog_posts_categories", "blog_categories"
  add_foreign_key "blog_posts_categories", "blog_posts"
  add_foreign_key "brochures", "companies"
  add_foreign_key "budget_lines", "budgets", on_delete: :cascade
  add_foreign_key "budget_lines", "chart_of_accounts"
  add_foreign_key "budgets", "companies"
  add_foreign_key "budgets", "locations"
  add_foreign_key "budgets", "users", column: "approved_by_id"
  add_foreign_key "budgets", "users", column: "created_by_id"
  add_foreign_key "budgets", "users", column: "locked_by_id"
  add_foreign_key "campaign_audiences", "audiences", column: "saved_audience_id"
  add_foreign_key "campaign_audiences", "campaigns"
  add_foreign_key "campaign_enrollments", "campaigns"
  add_foreign_key "campaign_events", "campaigns"
  add_foreign_key "campaign_sends", "campaign_enrollments"
  add_foreign_key "campaign_sends", "campaign_steps"
  add_foreign_key "campaign_sends", "campaigns"
  add_foreign_key "campaign_steps", "campaigns"
  add_foreign_key "cash_receipt_applications", "cash_receipts", on_delete: :cascade
  add_foreign_key "cash_receipt_applications", "invoices"
  add_foreign_key "cash_receipts", "accounts"
  add_foreign_key "cash_receipts", "bank_accounts"
  add_foreign_key "cash_receipts", "companies"
  add_foreign_key "cash_receipts", "contacts"
  add_foreign_key "cash_receipts", "journal_entries"
  add_foreign_key "cash_receipts", "locations"
  add_foreign_key "cash_receipts", "users", column: "created_by_id"
  add_foreign_key "champion_ims_retailers", "companies"
  add_foreign_key "champion_ims_retailers", "locations"
  add_foreign_key "champion_ims_sync_events", "champion_ims_sync_runs"
  add_foreign_key "champion_ims_sync_events", "vehicles"
  add_foreign_key "champion_ims_sync_runs", "champion_ims_retailers"
  add_foreign_key "champion_ims_sync_runs", "companies"
  add_foreign_key "champion_lead_feed_configs", "companies"
  add_foreign_key "champion_lead_feed_configs", "locations"
  add_foreign_key "champion_lead_feed_configs", "users", column: "default_lead_owner_id"
  add_foreign_key "chart_of_accounts", "bank_accounts"
  add_foreign_key "chart_of_accounts", "chart_of_accounts", column: "parent_id"
  add_foreign_key "chart_of_accounts", "companies"
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
  add_foreign_key "company_allowance_defaults", "companies"
  add_foreign_key "company_domains", "companies"
  add_foreign_key "company_domains", "websites"
  add_foreign_key "company_floor_plan_option_overrides", "companies"
  add_foreign_key "company_floor_plan_option_overrides", "floor_plan_options"
  add_foreign_key "company_floor_plans", "companies"
  add_foreign_key "company_floor_plans", "floor_plans"
  add_foreign_key "company_hidden_roles", "companies"
  add_foreign_key "company_hidden_roles", "roles"
  add_foreign_key "company_manufacturers", "companies"
  add_foreign_key "company_manufacturers", "manufacturers"
  add_foreign_key "configurations", "companies"
  add_foreign_key "configurations", "floor_plans"
  add_foreign_key "configurations", "users"
  add_foreign_key "contact_activities", "accounts"
  add_foreign_key "contact_activities", "contact_activities", column: "related_activity_id"
  add_foreign_key "contact_activities", "contacts"
  add_foreign_key "contact_activities", "users"
  add_foreign_key "contact_activities", "users", column: "assigned_to_id"
  add_foreign_key "contacts", "locations"
  add_foreign_key "contractor_assignments", "companies"
  add_foreign_key "contractor_assignments", "users", column: "assigned_by_id"
  add_foreign_key "contractor_assignments", "vendors", on_delete: :nullify
  add_foreign_key "custom_field_migrations", "companies"
  add_foreign_key "custom_field_migrations", "custom_fields", column: "source_custom_field_id"
  add_foreign_key "custom_field_migrations", "custom_fields", column: "target_custom_field_id"
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
  add_foreign_key "deal_desk_scenarios", "companies"
  add_foreign_key "deal_desk_scenarios", "deals"
  add_foreign_key "deal_desk_scenarios", "lender_programs"
  add_foreign_key "deal_desk_scenarios", "locations"
  add_foreign_key "deal_desk_scenarios", "quotes"
  add_foreign_key "deal_desk_scenarios", "users", column: "created_by_id"
  add_foreign_key "deal_desk_scenarios", "vehicles"
  add_foreign_key "deal_products", "deals"
  add_foreign_key "deal_stage_histories", "deals"
  add_foreign_key "deal_stage_histories", "users", column: "changed_by_id"
  add_foreign_key "deals", "accounts"
  add_foreign_key "deals", "commission_plans"
  add_foreign_key "deals", "companies"
  add_foreign_key "deals", "contacts"
  add_foreign_key "deals", "lenders"
  add_foreign_key "deals", "locations"
  add_foreign_key "deals", "projects"
  add_foreign_key "deals", "sources"
  add_foreign_key "deals", "users"
  add_foreign_key "deals", "users", column: "desk_manager_id"
  add_foreign_key "deals", "users", column: "finance_manager_id"
  add_foreign_key "deals", "users", column: "primary_salesperson_id"
  add_foreign_key "deals", "users", column: "sales_manager_id"
  add_foreign_key "deals", "users", column: "secondary_salesperson_id"
  add_foreign_key "entity_buyers", "companies"
  add_foreign_key "entity_buyers", "contacts"
  add_foreign_key "export_jobs", "companies"
  add_foreign_key "export_jobs", "users"
  add_foreign_key "factories", "manufacturers"
  add_foreign_key "fee_templates", "companies"
  add_foreign_key "field_option_overrides", "companies"
  add_foreign_key "fiscal_periods", "companies"
  add_foreign_key "fiscal_periods", "users", column: "closed_by_id"
  add_foreign_key "floor_plan_option_applicabilities", "floor_plan_options"
  add_foreign_key "floor_plan_option_applicabilities", "floor_plans"
  add_foreign_key "floor_plan_options", "factories"
  add_foreign_key "floor_plan_options", "option_categories"
  add_foreign_key "floor_plans", "factories"
  add_foreign_key "floor_plans", "manufacturers"
  add_foreign_key "fni_products", "companies"
  add_foreign_key "import_jobs", "companies"
  add_foreign_key "import_jobs", "users"
  add_foreign_key "import_templates", "companies"
  add_foreign_key "intake_forms", "companies"
  add_foreign_key "intake_forms", "sources"
  add_foreign_key "intake_forms", "users", column: "notified_user_id"
  add_foreign_key "intake_submissions", "leads"
  add_foreign_key "inventory_features", "companies"
  add_foreign_key "inventory_features", "vehicles"
  add_foreign_key "inventory_packages", "package_templates"
  add_foreign_key "inventory_packages", "vehicles"
  add_foreign_key "inventory_transactions", "bins"
  add_foreign_key "inventory_transactions", "companies"
  add_foreign_key "inventory_transactions", "inventory_transactions", column: "source_transaction_id"
  add_foreign_key "inventory_transactions", "locations"
  add_foreign_key "inventory_transactions", "parts"
  add_foreign_key "inventory_transactions", "purchase_order_lines"
  add_foreign_key "inventory_transactions", "users", column: "created_by_id"
  add_foreign_key "invitations", "companies"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "invoice_inventory_usages", "companies"
  add_foreign_key "invoice_inventory_usages", "invoice_items"
  add_foreign_key "invoice_inventory_usages", "invoices"
  add_foreign_key "invoice_inventory_usages", "users", column: "marked_by_id"
  add_foreign_key "invoice_items", "invoices"
  add_foreign_key "invoice_items", "listings"
  add_foreign_key "invoices", "companies"
  add_foreign_key "invoices", "contacts"
  add_foreign_key "invoices", "deals"
  add_foreign_key "invoices", "listings"
  add_foreign_key "invoices", "locations"
  add_foreign_key "journal_entries", "companies"
  add_foreign_key "journal_entries", "journal_entries", column: "reversed_by_id"
  add_foreign_key "journal_entries", "users", column: "posted_by_id"
  add_foreign_key "journal_entries", "users", column: "voided_by_id"
  add_foreign_key "journal_entry_lines", "chart_of_accounts"
  add_foreign_key "journal_entry_lines", "contacts"
  add_foreign_key "journal_entry_lines", "deals"
  add_foreign_key "journal_entry_lines", "journal_entries"
  add_foreign_key "journal_entry_lines", "locations"
  add_foreign_key "journal_entry_lines", "vehicles"
  add_foreign_key "knowledge_articles", "knowledge_features"
  add_foreign_key "knowledge_articles", "knowledge_modules"
  add_foreign_key "knowledge_change_queue", "knowledge_snapshots"
  add_foreign_key "knowledge_change_queue", "users", column: "reviewed_by_id"
  add_foreign_key "knowledge_features", "knowledge_modules"
  add_foreign_key "knowledge_searches", "users"
  add_foreign_key "knowledge_ui_elements", "knowledge_features"
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
  add_foreign_key "leads", "vehicles"
  add_foreign_key "lender_allowance_items", "companies"
  add_foreign_key "lender_allowance_items", "company_allowance_defaults"
  add_foreign_key "lender_allowance_items", "lenders"
  add_foreign_key "lender_deletion_items", "companies"
  add_foreign_key "lender_deletion_items", "lenders"
  add_foreign_key "lender_markup_configs", "companies"
  add_foreign_key "lender_markup_configs", "lenders"
  add_foreign_key "lender_program_tiers", "lender_programs"
  add_foreign_key "lender_programs", "companies"
  add_foreign_key "lenders", "companies"
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
  add_foreign_key "marketing_content", "knowledge_features"
  add_foreign_key "marketing_content", "knowledge_modules"
  add_foreign_key "notes", "users"
  add_foreign_key "nurture_enrollments", "companies"
  add_foreign_key "nurture_enrollments", "leads"
  add_foreign_key "nurture_enrollments", "nurture_sequences"
  add_foreign_key "nurture_sequences", "companies"
  add_foreign_key "nurture_steps", "nurture_sequences"
  add_foreign_key "nurture_steps", "templates"
  add_foreign_key "offline_sync_logs", "companies"
  add_foreign_key "offline_sync_logs", "users"
  add_foreign_key "option_categories", "factories"
  add_foreign_key "option_categories", "floor_plans"
  add_foreign_key "package_templates", "companies"
  add_foreign_key "part_categories", "companies"
  add_foreign_key "part_categories", "part_categories", column: "parent_id"
  add_foreign_key "part_categories", "users", column: "created_by_id"
  add_foreign_key "part_categories", "users", column: "updated_by_id"
  add_foreign_key "parts", "companies"
  add_foreign_key "parts", "factories"
  add_foreign_key "parts", "floor_plans"
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
  add_foreign_key "pending_import_links", "companies"
  add_foreign_key "pending_import_links", "import_jobs"
  add_foreign_key "printed_checks", "bank_accounts"
  add_foreign_key "printed_checks", "bill_payments"
  add_foreign_key "printed_checks", "bills"
  add_foreign_key "printed_checks", "companies"
  add_foreign_key "printed_checks", "contacts"
  add_foreign_key "printed_checks", "journal_entries"
  add_foreign_key "printed_checks", "vendors"
  add_foreign_key "project_cost_items", "companies"
  add_foreign_key "project_cost_items", "inventory_transactions", on_delete: :nullify
  add_foreign_key "project_cost_items", "parts", on_delete: :nullify
  add_foreign_key "project_cost_items", "project_phases"
  add_foreign_key "project_cost_items", "project_tasks"
  add_foreign_key "project_cost_items", "projects"
  add_foreign_key "project_cost_items", "users", column: "approved_by_id", on_delete: :nullify
  add_foreign_key "project_cost_items", "vendors", on_delete: :nullify
  add_foreign_key "project_documents", "companies"
  add_foreign_key "project_documents", "projects"
  add_foreign_key "project_documents", "users", column: "uploaded_by_id", on_delete: :nullify
  add_foreign_key "project_material_usages", "bins", on_delete: :nullify
  add_foreign_key "project_material_usages", "companies"
  add_foreign_key "project_material_usages", "locations"
  add_foreign_key "project_material_usages", "parts"
  add_foreign_key "project_material_usages", "project_phases"
  add_foreign_key "project_material_usages", "project_tasks"
  add_foreign_key "project_material_usages", "projects"
  add_foreign_key "project_material_usages", "users", column: "checked_out_by_id", on_delete: :nullify
  add_foreign_key "project_material_usages", "users", column: "returned_by_id", on_delete: :nullify
  add_foreign_key "project_material_usages", "users", column: "used_by_id", on_delete: :nullify
  add_foreign_key "project_notification_preferences", "companies"
  add_foreign_key "project_notification_preferences", "projects"
  add_foreign_key "project_phase_tasks", "companies"
  add_foreign_key "project_phase_tasks", "project_phases"
  add_foreign_key "project_phase_tasks", "users", column: "assigned_to_id", on_delete: :nullify
  add_foreign_key "project_phase_tasks", "users", column: "completed_by_id"
  add_foreign_key "project_phases", "companies"
  add_foreign_key "project_phases", "projects"
  add_foreign_key "project_task_checklist_items", "project_task_checklists"
  add_foreign_key "project_task_checklist_items", "users", column: "completed_by_id"
  add_foreign_key "project_task_checklists", "project_tasks"
  add_foreign_key "project_task_dependencies", "project_tasks", column: "depends_on_id"
  add_foreign_key "project_task_dependencies", "project_tasks", column: "task_id"
  add_foreign_key "project_tasks", "companies"
  add_foreign_key "project_tasks", "project_phases"
  add_foreign_key "project_tasks", "projects"
  add_foreign_key "project_tasks", "users", column: "assigned_to_id"
  add_foreign_key "project_template_phase_tasks", "project_template_phases"
  add_foreign_key "project_template_phases", "project_templates"
  add_foreign_key "project_templates", "companies"
  add_foreign_key "project_templates", "locations"
  add_foreign_key "projects", "companies"
  add_foreign_key "projects", "deals"
  add_foreign_key "projects", "land_parcels", on_delete: :nullify
  add_foreign_key "projects", "locations"
  add_foreign_key "projects", "project_templates"
  add_foreign_key "purchase_order_lines", "parts"
  add_foreign_key "purchase_order_lines", "purchase_orders"
  add_foreign_key "purchase_orders", "companies"
  add_foreign_key "purchase_orders", "locations"
  add_foreign_key "purchase_orders", "suppliers"
  add_foreign_key "purchase_orders", "users", column: "approved_by_id"
  add_foreign_key "purchase_orders", "users", column: "created_by_id"
  add_foreign_key "quickbooks_connections", "companies"
  add_foreign_key "quickbooks_entity_mappings", "companies"
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
  add_foreign_key "recurring_bills", "chart_of_accounts", column: "expense_account_id"
  add_foreign_key "recurring_bills", "chart_of_accounts", column: "payment_account_id"
  add_foreign_key "recurring_bills", "companies"
  add_foreign_key "recurring_bills", "contacts"
  add_foreign_key "recurring_bills", "locations"
  add_foreign_key "recurring_bills", "suppliers"
  add_foreign_key "recurring_journal_entries", "companies"
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
  add_foreign_key "service_tickets", "deals", on_delete: :nullify
  add_foreign_key "service_tickets", "locations"
  add_foreign_key "service_tickets", "vehicles"
  add_foreign_key "service_tickets", "warranty_claims", on_delete: :nullify
  add_foreign_key "sms_reply_tokens", "companies"
  add_foreign_key "sms_usage_logs", "companies"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
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
  add_foreign_key "tour_steps", "tours"
  add_foreign_key "tours", "knowledge_modules"
  add_foreign_key "tracked_link_events", "tracked_links"
  add_foreign_key "tracked_links", "communications"
  add_foreign_key "tracked_links", "companies"
  add_foreign_key "twilio_accounts", "companies"
  add_foreign_key "user_email_connections", "companies"
  add_foreign_key "user_email_connections", "users"
  add_foreign_key "user_locations", "companies"
  add_foreign_key "user_locations", "locations"
  add_foreign_key "user_locations", "users"
  add_foreign_key "user_role_assignments", "companies", on_delete: :cascade
  add_foreign_key "user_role_assignments", "roles", on_delete: :cascade
  add_foreign_key "user_role_assignments", "users", column: "assigned_by_id", on_delete: :nullify
  add_foreign_key "user_role_assignments", "users", on_delete: :cascade
  add_foreign_key "user_tour_completions", "tours"
  add_foreign_key "user_tour_completions", "users"
  add_foreign_key "user_view_preferences", "companies"
  add_foreign_key "user_view_preferences", "custom_views", column: "active_view_id"
  add_foreign_key "user_view_preferences", "users"
  add_foreign_key "users", "companies"
  add_foreign_key "users", "invitations"
  add_foreign_key "vehicle_documents", "users", column: "uploaded_by_user_id"
  add_foreign_key "vehicle_documents", "vehicles"
  add_foreign_key "vehicle_invoices", "companies"
  add_foreign_key "vehicle_invoices", "vehicle_documents", column: "scanned_document_id", on_delete: :nullify
  add_foreign_key "vehicle_invoices", "vehicles"
  add_foreign_key "vehicles", "companies"
  add_foreign_key "vehicles", "floor_plans"
  add_foreign_key "vehicles", "locations"
  add_foreign_key "vehicles", "vehicles", column: "cloned_from_id"
  add_foreign_key "vendors", "companies"
  add_foreign_key "warranty_claims", "companies", on_delete: :cascade
  add_foreign_key "warranty_claims", "locations", on_delete: :nullify
  add_foreign_key "warranty_claims", "manufacturers", on_delete: :restrict
  add_foreign_key "warranty_claims", "service_tickets", on_delete: :restrict
  add_foreign_key "website_media", "companies"
  add_foreign_key "website_media", "users", column: "uploaded_by_id"
  add_foreign_key "website_media", "websites"
  add_foreign_key "website_pages", "websites"
  add_foreign_key "website_versions", "users", column: "created_by_id"
  add_foreign_key "website_versions", "websites"
  add_foreign_key "websites", "companies"
  add_foreign_key "websites", "locations"
  add_foreign_key "win_loss_reports", "deals"
  add_foreign_key "win_loss_reports", "users"
  add_foreign_key "workflow_ai_generations", "companies"
  add_foreign_key "workflow_ai_generations", "users"
  add_foreign_key "workflow_ai_generations", "workflow_rules"
  add_foreign_key "workflow_approvals", "companies"
  add_foreign_key "workflow_approvals", "users", column: "approver_user_id"
  add_foreign_key "workflow_approvals", "workflow_runs"
  add_foreign_key "workflow_events", "companies"
  add_foreign_key "workflow_inbound_triggers", "companies"
  add_foreign_key "workflow_inbound_triggers", "workflow_rules"
  add_foreign_key "workflow_rules", "companies"
  add_foreign_key "workflow_rules", "users", column: "created_by_user_id"
  add_foreign_key "workflow_run_steps", "workflow_runs"
  add_foreign_key "workflow_runs", "companies"
  add_foreign_key "workflow_runs", "workflow_rules"
  add_foreign_key "workflow_runs", "workflow_runs", column: "parent_run_id"
  add_foreign_key "workflow_subscriptions", "companies"
  add_foreign_key "workflow_subscriptions", "workflow_rules"
end
