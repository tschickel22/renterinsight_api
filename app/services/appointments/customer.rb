# frozen_string_literal: true

module Appointments
  # Who an appointment is with, for reminders and invites: the lead, contact
  # or account the activity sits on, with the email and phone to reach them.
  Customer = Struct.new(:record, :name, :email, :phone, :company, keyword_init: true) do
    def self.for(activity)
      record = activity.try(:lead) || activity.try(:contact) || activity.try(:account)
      return nil unless record

      name = record.try(:full_name).presence || record.try(:name).presence ||
             [record.try(:first_name), record.try(:last_name)].compact.join(' ').presence
      new(record: record, name: name, email: record.try(:email).presence, phone: record.try(:phone).presence,
          company: record.try(:company))
    end
  end
end
