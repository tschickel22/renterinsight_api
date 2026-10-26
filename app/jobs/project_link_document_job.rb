# frozen_string_literal: true

# Copies a shared project photo or file to the other company on a link, or
# removes the copy (E68). A job because it copies the file in storage.
class ProjectLinkDocumentJob < ApplicationJob
  queue_as :default

  def perform(document_id)
    doc = ProjectDocument.find_by(id: document_id)
    ProjectLinkDocuments.new(doc).sync! if doc
  end
end
