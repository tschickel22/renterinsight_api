# frozen_string_literal: true

module Appointments
  # Texts the customer when an appointment is booked, moved or cancelled, so
  # the time reaches their phone as well as the calendar invite reaching their
  # inbox (Tom, 2026-11-06, E96). Same gates as the reminders: the
  # appointment's "remind customer" box and the company's reminder settings
  # with texts on. Sent through CommunicationService, so opt-outs are honoured
  # and, when the customer is in an Inbox conversation, it goes out on that
  # conversation's number and lands in the thread.
  module BookingText
    KINDS = %w[booked moved cancelled].freeze

    module_function

    def deliver(activity, kind)
      return nil unless KINDS.include?(kind) && activity.activity_type == 'meeting' && activity.start_time
      return nil unless activity.try(:remind_customer)

      customer = Customer.for(activity)
      return nil if customer.nil? || customer.company.nil? || customer.phone.blank?

      settings = ReminderSettings.for(customer.company)
      return nil unless settings['enabled'] && Array(settings['channels']).include?('sms')

      rep = activity.assigned_to || activity.user
      CommunicationService.send_sms(
        communicable: customer.record, to: customer.phone, body: body(activity, customer, rep, kind),
        category: 'transactional', sender_user_id: rep&.id,
        metadata: { source: 'appointment_booking', activity_type: activity.class.name, activity_id: activity.id, kind: kind }
      )
    rescue StandardError => e
      Rails.logger.warn("[Appointments::BookingText] #{activity.class.name} #{activity.id} #{kind}: #{e.class}: #{e.message}")
      nil
    end

    # links: false for a text message. A video meeting link is then left to
    # the email invite: dealer numbers are registered without links.
    def body(activity, customer, rep, kind, links: false)
      when_text = TimeText.for(activity, customer.company)
      with = [rep.try(:first_name).presence, customer.company.name].compact.join(' at ')
      at = place_phrase(activity, links: links)
      case kind
      when 'booked' then "You are set for #{when_text}#{at} with #{with}. Reply here if you need to change the time."
      when 'moved' then "Your appointment with #{with} has moved to #{when_text}#{at}. Reply here if that does not work."
      else "Your appointment with #{with} on #{when_text} is cancelled. Reply here if you would like a new time."
      end
    end

    # " at 12 Main St", " on a video call: https://...", or "" when no place.
    def place_phrase(activity, links: false)
      place = activity.try(:meeting_location).presence || activity.try(:location).presence
      return '' unless place
      return " at #{place}" unless place.match?(%r{\Ahttps?://}i) || place.casecmp?('Video call')
      return ' by video call' if place.casecmp?('Video call')

      links ? " on a video call: #{place}" : ' by video call (the link to join is in your email invite)'
    end
  end
end
