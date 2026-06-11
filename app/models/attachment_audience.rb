# frozen_string_literal: true

# Audience tags for a single ActiveStorage attachment. Internal/staff always have
# access; these booleans additionally expose the file to the customer portal and/or
# the manufacturer (via warranty claim). See CreateAttachmentAudiences migration.
class AttachmentAudience < ApplicationRecord
  belongs_to :attachment, class_name: 'ActiveStorage::Attachment',
             foreign_key: :active_storage_attachment_id, optional: true

  # Returns a hash of { attachment_id => AttachmentAudience } for the given
  # attachment ids, for N+1-free serialization.
  def self.map_for(attachment_ids)
    where(active_storage_attachment_id: attachment_ids).index_by(&:active_storage_attachment_id)
  end
end
