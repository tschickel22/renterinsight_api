# frozen_string_literal: true

# Backfill AttachmentAudience rows for existing service-ticket attachments that
# were uploaded before sharing defaulted to "visible to both". Going forward,
# ServiceTicketsController#upload_attachments creates these rows automatically;
# this migration covers files that predate that change.
#
# Scope: only ActiveStorage attachments on ServiceTicket records (name =
# 'attachments') that have no audience row yet. Existing rows (where a user
# already toggled visibility) are left untouched.
class BackfillAttachmentAudiencesForServiceTickets < ActiveRecord::Migration[8.0]
  def up
    now = Time.current

    execute(<<~SQL)
      INSERT INTO attachment_audiences
        (active_storage_attachment_id, visible_to_customer, visible_to_manufacturer, created_at, updated_at)
      SELECT asa.id, true, true, '#{now.utc.iso8601}', '#{now.utc.iso8601}'
      FROM active_storage_attachments asa
      LEFT JOIN attachment_audiences aa
        ON aa.active_storage_attachment_id = asa.id
      WHERE asa.record_type = 'ServiceTicket'
        AND asa.name = 'attachments'
        AND aa.id IS NULL
    SQL
  end

  def down
    # Irreversible data backfill: we cannot distinguish backfilled rows (both
    # flags true) from rows a user intentionally set both-true. No-op on down.
  end
end
