# frozen_string_literal: true

# Customer reminders and calendar invites are on by default for appointments
# made from now on. Appointments booked before they existed must not start
# texting customers who were never told, so every existing row is turned off.
class ExistingAppointmentsSkipCustomerNotices < ActiveRecord::Migration[8.0]
  TABLES = %i[lead_activities contact_activities account_activities].freeze

  def up
    TABLES.each do |table|
      changed = exec_update("UPDATE #{table} SET remind_customer = FALSE, send_calendar_invite = FALSE")
      say "#{table}: #{changed} existing rows set to no customer reminders or invites"
    end
  end

  def down; end
end
