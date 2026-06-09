# frozen_string_literal: true

# Backfills existing single-field service ticket notes into the Note model so the
# new timestamped/user-stamped UI shows historical content. Maps:
#   service_tickets.notes               -> Note(category: "customer")
#   custom_fields["technicianNotes"]    -> Note(category: "technician")
# Notes are stamped with the ticket's updated_at and attributed to "Imported"
# (original author is unknown in the legacy single-field design). Idempotent: skips
# tickets that already have a backfilled note for the given category.
class BackfillServiceTicketNotes < ActiveRecord::Migration[8.0]
  def up
    ServiceTicket.reset_column_information

    ServiceTicket.find_each do |ticket|
      backfill_note(ticket, 'customer', ticket.notes)

      custom = ticket.custom_fields
      custom = (JSON.parse(custom) rescue {}) unless custom.is_a?(Hash)
      backfill_note(ticket, 'technician', custom.is_a?(Hash) ? custom['technicianNotes'] : nil)
    end
  end

  def down
    Note.where(entity_type: 'service_ticket', created_by_name: 'Imported')
        .where(category: %w[customer technician])
        .delete_all
  end

  private

  def backfill_note(ticket, category, content)
    return if content.blank?
    return if Note.exists?(entity_type: 'service_ticket', entity_id: ticket.id.to_s, category: category, created_by_name: 'Imported')

    Note.create!(
      entity_type: 'service_ticket',
      entity_id: ticket.id.to_s,
      category: category,
      content: content,
      created_by_name: 'Imported',
      created_at: ticket.updated_at,
      updated_at: ticket.updated_at
    )
  end
end
