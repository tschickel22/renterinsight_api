# frozen_string_literal: true

class BackfillLastActivityAt < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      UPDATE leads SET last_activity_at = sub.max_at
      FROM (
        SELECT parent_id, MAX(created_at) AS max_at
        FROM workqueue_activities
        WHERE parent_type = 'Lead'
        GROUP BY parent_id
      ) sub
      WHERE leads.id = sub.parent_id;
    SQL

    execute <<~SQL
      UPDATE deals SET last_activity_at = sub.max_at
      FROM (
        SELECT parent_id, MAX(created_at) AS max_at
        FROM workqueue_activities
        WHERE parent_type = 'Deal'
        GROUP BY parent_id
      ) sub
      WHERE deals.id = sub.parent_id;
    SQL
  end

  def down
    # no-op — columns dropped by rolling back add_last_activity_at migration
  end
end
