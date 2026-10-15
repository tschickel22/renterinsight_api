# frozen_string_literal: true

# Appointments: remind the customer (text and email before it) and send
# calendar invites (to the assignee, and to the customer when on). Both on by
# default (Tom, 2026-10-13). customer_notices records what went out: which
# reminders, and the invite's sequence so updates replace it in calendars.
class AddCustomerNoticesToActivities < ActiveRecord::Migration[8.0]
  TABLES = %i[lead_activities contact_activities account_activities].freeze

  def change
    TABLES.each do |table|
      add_column table, :remind_customer, :boolean, default: true, null: false
      add_column table, :send_calendar_invite, :boolean, default: true, null: false
      add_column table, :customer_notices, :jsonb, default: {}, null: false
    end
  end
end
