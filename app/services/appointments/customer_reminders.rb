# frozen_string_literal: true

module Appointments
  # Texts and emails customers ahead of their appointments, at the company's
  # chosen times (ReminderSettings). Runs every five minutes.
  #
  # Sent through CommunicationService, so it checks opt-outs and suppressions,
  # logs the message on the customer's record (and so on their timeline), and
  # texts from the location's or company's number, falling back to the
  # platform's. A reminder is sent once; an appointment made too late for the
  # earlier ones gets only the latest that is due, not a burst.
  class CustomerReminders
    MODELS = [LeadActivity, ContactActivity, AccountActivity, DealActivity].freeze
    LATEST_OFFSET = ReminderSettings::OFFSETS.values.max

    def self.run(now: Time.current)
      MODELS.sum { |model| new(model, now).run }
    end

    def initialize(model, now)
      @model = model
      @now = now
    end

    def run
      due = @model.where(activity_type: 'meeting', status: 'pending', remind_customer: true)
                  .where(start_time: (@now + 5.minutes)..(@now + LATEST_OFFSET + 10.minutes))
      sent = 0
      due.find_each { |activity| sent += 1 if remind(activity) }
      sent
    end

    private

    def remind(activity)
      customer = Customer.for(activity)
      return false unless customer&.company

      settings = ReminderSettings.for(customer.company)
      return false unless settings['enabled']

      notices = activity.customer_notices.to_h
      done = notices['reminders'].to_h
      # Due now, not yet sent: of those, only the closest to the start.
      due = settings['offsets'].select { |o| done[o].nil? && activity.start_time - ReminderSettings::OFFSETS[o] <= @now }
      return false if due.empty?

      offset = due.min_by { |o| ReminderSettings::OFFSETS[o] }
      results = settings['channels'].filter_map { |channel| deliver(activity, customer, channel) }
      stamp = @now.iso8601
      due.each { |o| done[o] = o == offset ? stamp : "skipped #{stamp}" }
      activity.update_columns(customer_notices: notices.merge('reminders' => done))
      results.any?
    rescue StandardError => e
      Rails.logger.warn("[Appointments::CustomerReminders] #{activity.class.name} #{activity.id}: #{e.class}: #{e.message}")
      false
    end

    # Sent as the assigned rep: email from their connected mailbox (falling
    # back to the company address when it cannot send), and text replies
    # forwarded to them. Never as whoever booked the appointment.
    def deliver(activity, customer, channel)
      rep = activity.assigned_to || activity.user
      when_text = TimeText.for(activity, customer.company)
      place = activity.try(:meeting_location).presence || activity.try(:location).presence
      company = customer.company.name
      with = [rep.try(:first_name).presence, company].compact.join(' at ')
      metadata = { 'source' => 'appointment_reminder', 'activity_type' => activity.class.name, 'activity_id' => activity.id }
      case channel
      when 'sms'
        return nil if customer.phone.blank?

        body = "Reminder: your appointment with #{with} is #{when_text}#{" at #{place}" if place}. Reply here with any questions."
        CommunicationService.send_sms(communicable: customer.record, to: customer.phone, body: body, category: 'transactional',
                                      sender_user_id: rep&.id, metadata: metadata)
      when 'email'
        return nil if customer.email.blank?

        greeting = customer.record.try(:first_name).presence || customer.name
        body = <<~HTML
          <p>Hi#{" #{ERB::Util.h(greeting)}" if greeting},</p>
          <p>This is a reminder of your appointment with #{ERB::Util.h(with)} on <strong>#{ERB::Util.h(when_text)}</strong>#{place ? " at #{ERB::Util.h(place)}" : ''}.</p>
          <p>If anything changes, just reply to this email.</p>
        HTML
        args = { communicable: customer.record, to: customer.email, subject: "Reminder: your appointment #{when_text}",
                 body: body, category: 'transactional', metadata: metadata }
        if RepMailbox.connection_for(rep)
          result = CommunicationService.send_email(**args, user: rep)
          return result unless result.is_a?(Hash) && result[:success] == false
        end
        CommunicationService.send_email(**args)
      end
    end
  end
end
