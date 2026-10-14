# frozen_string_literal: true

module Appointments
  # Who an appointment is with, for reminders and invites: the lead, contact
  # or account the activity sits on, with the email and phone to reach them.
  # A deal's appointment is with the deal's buyer: its contact, else its
  # account.
  Customer = Struct.new(:record, :name, :email, :phone, :company, keyword_init: true) do
    def self.for(activity)
      record = activity.try(:lead) || activity.try(:contact) || activity.try(:account) || deal_buyer(activity.try(:deal))
      return nil unless record

      name = record.try(:full_name).presence || record.try(:name).presence ||
             [record.try(:first_name), record.try(:last_name)].compact.join(' ').presence
      new(record: record, name: name, email: record.try(:email).presence, phone: record.try(:phone).presence,
          company: record.try(:company))
    end

    def self.deal_buyer(deal)
      return nil unless deal

      [deal.contact, deal.account].compact.find { |r| r.try(:email).present? || r.try(:phone).present? } ||
        deal.contact || deal.account
    end
  end
end
