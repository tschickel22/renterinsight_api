# frozen_string_literal: true

class AddNameAndNotesToPortalDocuments < ActiveRecord::Migration[8.0]
  def change
    add_column :portal_documents, :document_name, :string
    add_column :portal_documents, :notes, :text
  end
end
