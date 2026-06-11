# frozen_string_literal: true

class AddUniqueIndexToWarrantyClaimsServiceTicket < ActiveRecord::Migration[8.0]
  # Enforces "one active warranty claim per service ticket" at the database level.
  # Partial index (WHERE is_deleted = false) so a soft-deleted claim does not
  # block creating a fresh one when warranty is re-marked.
  disable_ddl_transaction!

  def up
    # Guard: a unique index cannot be built if duplicates already exist.
    # Surface them with a readable error instead of a raw Postgres failure.
    duplicates = select_rows(<<~SQL)
      SELECT company_id, service_ticket_id, COUNT(*)
      FROM warranty_claims
      WHERE is_deleted = false
      GROUP BY company_id, service_ticket_id
      HAVING COUNT(*) > 1
    SQL

    if duplicates.any?
      details = duplicates.map { |c, st, n| "company #{c} / service_ticket #{st}: #{n} claims" }.join('; ')
      raise StandardError, "Cannot add unique index: existing duplicate active warranty claims -> #{details}. Resolve (soft-delete extras) before migrating."
    end

    add_index :warranty_claims,
              [:company_id, :service_ticket_id],
              unique: true,
              where: 'is_deleted = false',
              algorithm: :concurrently,
              name: 'idx_warranty_claims_one_active_per_ticket'
  end

  def down
    remove_index :warranty_claims, name: 'idx_warranty_claims_one_active_per_ticket'
  end
end
