class AllowNullDescriptionOnAccountActivities < ActiveRecord::Migration[8.0]
  # lead_activities.description is nullable, but account_activities.description
  # was NOT NULL. Migrating a lead with a null-description activity into an
  # account aborted the entire conversion (PG::NotNullViolation). Relax the
  # constraint so the two tables match; presence is enforced at the model layer
  # for the activity types that actually require it.
  def up
    change_column_null :account_activities, :description, true
  end

  def down
    change_column_null :account_activities, :description, false
  end
end
