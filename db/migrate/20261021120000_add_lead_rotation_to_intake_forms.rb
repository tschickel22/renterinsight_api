# frozen_string_literal: true

# An intake form decides who a new lead belongs to: one named person (what
# notified_user_id always did) or a rotation between reps. The rotation is a
# RoundRobinAssignmentList, the same list and cursor plays, API keys and
# workflows use, so a play running on a form shares the form's place in line
# instead of keeping a second one.
#
# Additive only. NULL assignment_mode reads as one person, so code already
# running during the release behaves exactly as before.
class AddLeadRotationToIntakeForms < ActiveRecord::Migration[8.0]
  def change
    add_column :intake_forms, :assignment_mode, :string
    add_column :intake_forms, :round_robin_list_id, :bigint
    add_index :intake_forms, :round_robin_list_id
  end
end
