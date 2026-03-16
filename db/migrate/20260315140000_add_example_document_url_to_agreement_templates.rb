class AddExampleDocumentUrlToAgreementTemplates < ActiveRecord::Migration[8.0]
  def change
    add_column :agreement_templates, :example_document_url, :string
  end
end
