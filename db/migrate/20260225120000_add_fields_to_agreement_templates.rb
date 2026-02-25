class AddFieldsToAgreementTemplates < ActiveRecord::Migration[8.0]
  def change
    add_column :agreement_templates, :merge_field_placements, :jsonb, default: [] unless column_exists?(:agreement_templates, :merge_field_placements)
    add_column :agreement_templates, :document_urls, :jsonb, default: [] unless column_exists?(:agreement_templates, :document_urls)
  end
end
