# frozen_string_literal: true

class DocumentPresenter
  def self.list_json(document)
    {
      id: document.id,
      document_name: document.document_name,
      category: document.category,
      description: document.description,
      notes: document.notes,
      admin_notes: document.admin_notes,
      filename: document.filename,
      content_type: document.content_type,
      size: document.size,
      uploaded_at: document.uploaded_at,
      uploaded_by: document.uploaded_by,
      download_url: document.download_url
    }
  end
  
  def self.detail_json(document)
    list_json(document).merge(
      related_to_type: document.related_to_type,
      related_to_id: document.related_to_id,
      created_at: document.created_at,
      updated_at: document.updated_at
    )
  end
end
