class MigrateLostStatusToLostLead < ActiveRecord::Migration[8.0]
  def up
    # The plain 'lost' status was an unintended emission from the Champion sync job;
    # the canonical status for a dead lead is 'lost_lead' (matches the frontend enum).
    execute("UPDATE leads SET status = 'lost_lead' WHERE status = 'lost'")
  end

  def down
    # Not reversible — 'lost' and 'lost_lead' rows are indistinguishable after merge.
  end
end
