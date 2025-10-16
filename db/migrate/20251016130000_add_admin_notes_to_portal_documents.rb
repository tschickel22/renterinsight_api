# frozen_string_literal: true

class AddAdminNotesToPortalDocuments < ActiveRecord::Migration[8.0]
  def change
    add_column :portal_documents, :admin_notes, :text
  end
end
