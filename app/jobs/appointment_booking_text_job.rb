# frozen_string_literal: true

# Texts the customer that an appointment was booked, moved or cancelled
# (Appointments::BookingText). Runs right after the change, next to the
# calendar invite.
class AppointmentBookingTextJob < ApplicationJob
  queue_as :default

  def perform(activity_class, activity_id, kind)
    activity = activity_class.constantize.find_by(id: activity_id)
    return unless activity

    Appointments::BookingText.deliver(activity, kind)
  end
end
