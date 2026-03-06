class AddPlatformTemplateSupport < ActiveRecord::Migration[8.0]
  def change
    # Platform template fields on agreement_templates
    add_column :agreement_templates, :state_code, :string unless column_exists?(:agreement_templates, :state_code)
    add_column :agreement_templates, :form_type, :string unless column_exists?(:agreement_templates, :form_type)
    add_column :agreement_templates, :form_number, :string unless column_exists?(:agreement_templates, :form_number)
    add_column :agreement_templates, :is_platform_template, :boolean, default: false, null: false unless column_exists?(:agreement_templates, :is_platform_template)
    add_column :agreement_templates, :custom_field_definitions, :jsonb, default: [], null: false unless column_exists?(:agreement_templates, :custom_field_definitions)
    add_column :agreement_templates, :page_count, :integer unless column_exists?(:agreement_templates, :page_count)

    # Custom field values on agreements (preparer fills these before sending)
    add_column :agreements, :custom_field_values, :jsonb, default: {}, null: false unless column_exists?(:agreements, :custom_field_values)

    # Optional equipment line items from deal (snapshot at agreement creation)
    add_column :agreements, :optional_equipment_snapshot, :jsonb, default: [], null: false unless column_exists?(:agreements, :optional_equipment_snapshot)

    # Indexes for platform template lookups
    unless index_exists?(:agreement_templates, [:is_platform_template, :state_code, :status])
      add_index :agreement_templates, [:is_platform_template, :state_code, :status],
                name: 'idx_platform_templates_state_lookup'
    end

    unless index_exists?(:agreement_templates, :form_number)
      add_index :agreement_templates, :form_number, name: 'idx_agr_templates_form_number'
    end

    unless index_exists?(:agreement_templates, :state_code)
      add_index :agreement_templates, :state_code, name: 'idx_agr_templates_state_code'
    end
  end
end
