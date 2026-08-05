# frozen_string_literal: true

# A library of canned complaints -- "Shingle repair", "Cracks in ceiling",
# "Front door stuck", "Formica popping on island". Effectively op codes: each
# row is one reusable issue, optionally carrying the labor allowance and parts
# that usually go with it.
#
# Modeled on fee_templates (flat, one row per item, real category column) rather
# than package_templates, which is RBAC-gated on :inventory and whose axes
# (applicable_to rv/mh, visibility_scope inventory/finance) don't apply here.
class CreateServiceIssueTemplates < ActiveRecord::Migration[8.0]
  def change
    create_table :service_issue_templates do |t|
      t.references :company, null: false, foreign_key: true
      t.references :location, null: true, foreign_key: true

      t.string :title, null: false
      t.string :category, null: false, default: 'general'
      t.text :complaint
      t.text :correction

      t.string :default_pay_type, null: false, default: 'warranty'
      t.decimal :default_hours, precision: 8, scale: 2
      t.decimal :default_rate, precision: 10, scale: 2
      t.jsonb :default_parts, null: false, default: []

      t.integer :position, null: false, default: 0
      t.boolean :is_active, null: false, default: true
      t.boolean :is_seeded, null: false, default: false

      t.timestamps
    end

    add_index :service_issue_templates, %i[company_id is_active]
    add_index :service_issue_templates, %i[company_id category]
    add_index :service_issue_templates, 'company_id, lower(title)',
              unique: true,
              name: 'idx_service_issue_templates_unique_title',
              where: 'is_active'
  end
end
