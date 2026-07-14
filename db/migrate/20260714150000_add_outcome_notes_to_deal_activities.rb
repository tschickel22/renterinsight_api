# Deal task close was routing free-text into the `outcome` enum column
# (validated as positive|neutral|negative), which 422'd every time a rep
# actually typed notes. Contact/lead/account activities already have an
# outcome_notes text column for exactly this purpose; deal_activities was
# the outlier. Adding the column so the notes have a real home.
class AddOutcomeNotesToDealActivities < ActiveRecord::Migration[8.0]
  def change
    add_column :deal_activities, :outcome_notes, :text
  end
end
