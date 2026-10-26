# frozen_string_literal: true

# E68: an installer's copy of a dealer task remembers the dealer task, so
# ticking it off in the installer's company ticks the dealer's off too.
# Nullable and new, so old and new code can run side by side.
class AddLinkedTaskIdToProjectPhaseTasks < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_column :project_phase_tasks, :linked_task_id, :bigint unless column_exists?(:project_phase_tasks, :linked_task_id)
    add_index :project_phase_tasks, :linked_task_id, algorithm: :concurrently, if_not_exists: true

    # Jobs accepted before this: the installer's tasks were copied from the
    # dealer's, so match them by phase and name.
    execute <<~SQL
      UPDATE project_phase_tasks it
         SET linked_task_id = dt.id
        FROM project_link_phases lp
        JOIN project_phase_tasks dt ON dt.project_phase_id = lp.dealer_phase_id
       WHERE it.project_phase_id = lp.installer_phase_id
         AND it.linked_task_id IS NULL
         AND lower(it.name) = lower(dt.name)
    SQL
  end

  def down
    remove_index :project_phase_tasks, :linked_task_id, if_exists: true
    remove_column :project_phase_tasks, :linked_task_id, if_exists: true
  end
end
