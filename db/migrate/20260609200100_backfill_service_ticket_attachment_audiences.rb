# frozen_string_literal: true

# Preserve today's behavior: the buyer portal currently shows ALL service ticket
# attachments. After introducing audience filtering, default existing ticket files
# to customer-visible (manufacturer stays opt-in). Idempotent.
class BackfillServiceTicketAttachmentAudiences < ActiveRecord::Migration[8.0]
  def up
    ActiveStorage::Attachment
      .where(record_type: 'ServiceTicket', name: 'attachments')
      .find_each do |att|
        next if AttachmentAudience.exists?(active_storage_attachment_id: att.id)

        AttachmentAudience.create!(
          active_storage_attachment_id: att.id,
          visible_to_customer: true,
          visible_to_manufacturer: false
        )
      end
  end

  def down
    # Tags are additive metadata; leave them in place on rollback.
  end
end
