# frozen_string_literal: true

module Assistant
  # A buyer's booked visits, for the Lead Assistant (E96): it can tell them when
  # and where, and send the calendar invite again. Booking and changing visits
  # stay with a person until the assistant books (next phase).
  module Appointments
    MODELS = { 'Lead' => [LeadActivity, :lead_id], 'Contact' => [ContactActivity, :contact_id] }.freeze

    module_function

    def upcoming_for(record, limit: 3)
      model, key = MODELS[record&.class&.name]
      return [] unless model

      model.where(key => record.id, activity_type: 'meeting', status: 'pending').where('start_time >= ?', Time.current)
           .order(:start_time).limit(limit).to_a
    end

    # The visit they most recently missed, when nothing was booked or held
    # since: Quinn's follow-ups then aim to win the visit back (E96).
    def last_missed(record, within: 60.days)
      model, key = MODELS[record&.class&.name]
      return nil unless model

      missed = model.where(key => record.id, activity_type: 'meeting', status: 'no_show')
                    .where('start_time >= ?', within.ago).order(start_time: :desc).first
      return nil unless missed
      return nil if model.where(key => record.id, activity_type: 'meeting', status: %w[pending completed])
                         .where('start_time > ?', missed.start_time).exists?

      missed
    end

    # Emails the next visit's calendar invite again (same event, so calendars
    # update in place). True when one was queued.
    def resend_invite(record)
      appt = upcoming_for(record, limit: 1).first
      return false unless appt && record.try(:email).present?

      AppointmentInviteJob.perform_later(appt.class.name, appt.id, 'REQUEST')
      true
    end
  end
end
