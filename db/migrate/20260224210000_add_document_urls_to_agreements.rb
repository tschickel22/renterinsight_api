class AddDocumentUrlsToAgreements < ActiveRecord::Migration[8.0]
  def change
    add_column :agreements, :document_urls, :jsonb, default: []
  end
end
