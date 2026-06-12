# frozen_string_literal: true

# One-time repair: draft warranty claims only re-synced their parts/labor from the
# ticket when billing was tagged, so later edits to a part's description/cost left
# the claim with a stale snapshot (blank description/part #). Going forward an
# after_update callback keeps them fresh; this backfills existing draft claims.
class ResyncStaleDraftWarrantyClaims < ActiveRecord::Migration[8.0]
  def up
    say_with_time 'Re-syncing draft warranty claims from their service tickets' do
      count = 0
      WarrantyClaim.where(status: 'draft', is_deleted: false).find_each do |claim|
        ticket = claim.service_ticket
        next unless ticket

        # Mirrors resync_draft_claim!: pull the ticket's currently warranty-tagged
        # lines so the claim reflects the latest descriptions/costs.
        claim.update_columns(
          parts: ticket.warranty_parts,
          labor: ticket.warranty_labor,
          estimated_amount: ticket.warranty_total
        )
        count += 1
      end
      count
    end
  end

  def down
    # No-op: this only refreshes data from the source of truth (the ticket).
  end
end
