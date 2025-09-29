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

ActiveRecord::Schema[8.0].define(version: 2025_09_27_192758) do
  create_table "companies", force: :cascade do |t|
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
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
    t.index ["source_id"], name: "index_leads_on_source_id"
  end

  create_table "nurture_enrollments", force: :cascade do |t|
    t.integer "lead_id", null: false
    t.integer "nurture_sequence_id", null: false
    t.string "status", default: "idle", null: false
    t.integer "current_step_index"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["lead_id", "nurture_sequence_id"], name: "index_nurture_enrollments_on_lead_id_and_nurture_sequence_id"
    t.index ["lead_id"], name: "index_nurture_enrollments_on_lead_id"
    t.index ["nurture_sequence_id"], name: "index_nurture_enrollments_on_nurture_sequence_id"
  end

  create_table "nurture_sequences", force: :cascade do |t|
    t.string "name", null: false
    t.boolean "is_active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
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
    t.index ["nurture_sequence_id", "position"], name: "index_nurture_steps_on_nurture_sequence_id_and_position"
    t.index ["nurture_sequence_id"], name: "index_nurture_steps_on_nurture_sequence_id"
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

  add_foreign_key "lead_tasks", "leads"
  add_foreign_key "leads", "sources"
  add_foreign_key "nurture_enrollments", "leads"
  add_foreign_key "nurture_enrollments", "nurture_sequences"
  add_foreign_key "nurture_steps", "nurture_sequences"
end
