# frozen_string_literal: true

class DocumentPresenter
  def self.list_json(document)
    {
      id: document.id,
      filename: document.filename,
      content_type: document.content_type,
      size: document.size,
      category: document.category,
      uploaded_at: document.uploaded_at,
      uploaded_by: document.uploaded_by,
      url: document.download_url
    }
  end
  
  def self.detail_json(document)
    list_json(document).merge(
      description: document.description,
      related_to: related_to_info(document)
    )
  end
  
  private
  
  def self.related_to_info(document)
    return nil unless document.related_to.present?
    
    {
      type: document.related_to_type,
      id: document.related_to_id,
      reference: reference_for(document.related_to)
    }
  end
  
  def self.reference_for(related)
    case related
    when Quote
      related.quote_number
    else
      related.id.to_s
    end
  end
end
