# frozen_string_literal: true

# Actual cost now counts only incurred lines; pending ones (an awarded bid, a
# linked installer's fee) are committed and reported apart. Recount the
# stored totals of projects and phases that have pending lines.
class ActualCostExcludesPending < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      WITH touched AS (
        SELECT DISTINCT project_id FROM project_cost_items
        WHERE status = 'pending' AND is_deleted IS NOT TRUE
      ), sums AS (
        SELECT t.project_id,
               COALESCE(SUM(i.amount), 0) AS total,
               COALESCE(SUM(i.amount) FILTER (WHERE i.cost_type = 'labor'), 0) AS labor,
               COALESCE(SUM(i.amount) FILTER (WHERE i.cost_type = 'materials'), 0) AS materials,
               COALESCE(SUM(i.amount) FILTER (WHERE i.cost_type = 'subcontractor'), 0) AS sub,
               COALESCE(SUM(i.amount) FILTER (WHERE i.cost_type NOT IN ('labor', 'materials', 'subcontractor')), 0) AS other
        FROM touched t
        LEFT JOIN project_cost_items i
          ON i.project_id = t.project_id AND i.is_deleted IS NOT TRUE AND i.status <> 'pending'
        GROUP BY t.project_id
      )
      UPDATE projects p
      SET actual_cost = s.total, labor_cost = s.labor, materials_cost = s.materials,
          subcontractor_cost = s.sub, other_cost = s.other
      FROM sums s WHERE p.id = s.project_id
    SQL

    execute <<~SQL
      WITH touched AS (
        SELECT DISTINCT project_phase_id FROM project_cost_items
        WHERE status = 'pending' AND is_deleted IS NOT TRUE AND project_phase_id IS NOT NULL
      )
      UPDATE project_phases ph
      SET actual_cost = COALESCE((
        SELECT SUM(i.amount) FROM project_cost_items i
        WHERE i.project_phase_id = ph.id AND i.is_deleted IS NOT TRUE AND i.status <> 'pending'
      ), 0)
      FROM touched t WHERE ph.id = t.project_phase_id
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
