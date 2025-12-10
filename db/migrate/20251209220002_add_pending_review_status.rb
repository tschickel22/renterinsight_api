# frozen_string_literal: true

class AddPendingReviewStatus < ActiveRecord::Migration[8.0]
  def up
    # No schema change - just documenting new status value
    # Status values for service_tickets: 
    # 'pending_review', 'open', 'in_progress', 'waiting_parts', 'completed', 'cancelled'
    # 
    # 'pending_review' is used when a service ticket is created via the client portal
    # and needs to be reviewed by staff before being assigned/started
  end
  
  def down
    # No-op - no schema change to revert
  end
end
