class AddLocationToIntakeForms < ActiveRecord::Migration[8.0]
  # Binds an intake form to a specific location so leads created from that
  # form land at the right lot instead of falling through to the Corporate
  # fallback in IntakeSubmission#create_lead_from_submission. Nullable so
  # existing forms keep their current behavior; opting into a location is a
  # per-form choice.
  def change
    add_reference :intake_forms, :location, null: true, foreign_key: true
  end
end
