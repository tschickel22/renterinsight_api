# frozen_string_literal: true

# Admin-defined custom fields for service tickets, matching the column every
# other page-layout module already uses.
#
# The pre-existing `custom_fields` jsonb column stays put: it is a fixed
# grab-bag the form writes directly (scheduledTime, estimatedHours,
# actualHours, estimatedCompletionDate, customerAuthorization, warrantyStatus,
# technicianNotes). Merging the two would break that form, so admin-defined
# fields get their own bag under the name the rest of the app expects.
class AddCustomFieldValuesToServiceTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :service_tickets, :custom_field_values, :jsonb, null: false, default: {}
    add_index :service_tickets, :custom_field_values, using: :gin
  end
end
