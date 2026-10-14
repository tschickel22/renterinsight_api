# frozen_string_literal: true

# Appointment reminders to customers (Appointments::CustomerReminders).
class CustomerAppointmentRemindersJob < ApplicationJob
  queue_as :default

  def perform
    Appointments::CustomerReminders.run
  end
end
