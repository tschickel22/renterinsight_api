# E69: a contractor or employee can own a whole project or phase, and project
# templates carry default assignments at the template, phase and task levels.
#
# Task-level work still runs through ContractorAssignment on ProjectPhaseTask
# (portal, review, notifications). A project or phase assignment is the owner
# that its tasks inherit from, not a new assignable.
class AddWholePhaseAndTemplateAssignments < ActiveRecord::Migration[8.0]
  def change
    %i[projects project_phases].each do |table|
      add_reference table, :assigned_vendor, foreign_key: { to_table: :vendors, on_delete: :nullify }
    end
    add_reference :projects, :assigned_to, foreign_key: { to_table: :users, on_delete: :nullify }
    add_reference :project_phases, :assigned_to, foreign_key: { to_table: :users, on_delete: :nullify }

    # Items a template meant to assign but could not at build time (inactive or
    # deleted vendor or user). The build leaves them unassigned and lists them here.
    add_column :projects, :assignment_issues, :jsonb, default: [], null: false

    %i[project_templates project_template_phases project_template_phase_tasks].each do |table|
      add_reference table, :default_vendor, foreign_key: { to_table: :vendors, on_delete: :nullify }
      add_reference table, :default_assigned_to, foreign_key: { to_table: :users, on_delete: :nullify }
    end
  end
end
