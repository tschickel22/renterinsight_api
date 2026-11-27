# Outside inboxes that get every inquiry from this form in full, for dealers
# who never sign in (The James reads leads in Gmail). Defaulted, so existing
# rows read as "forward to nobody" and old code running beside this during a
# release ignores the column.
class AddForwardToEmailsToIntakeForms < ActiveRecord::Migration[8.0]
  def change
    add_column :intake_forms, :forward_to_emails, :string, array: true, default: [], null: false
  end
end
