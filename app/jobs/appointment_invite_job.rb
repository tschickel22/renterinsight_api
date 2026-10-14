# frozen_string_literal: true

# Sends (or updates, or cancels) an appointment's calendar invite. Delivered
# synchronously inside the job so a failure is logged against the attempt.
class AppointmentInviteJob < ApplicationJob
  queue_as :default

  def perform(activity_class, activity_id, method = 'REQUEST')
    activity = activity_class.constantize.find_by(id: activity_id)
    return unless activity && activity.activity_type == 'meeting' && activity.start_time

    invite = Appointments::CalendarInvite.new(activity, method: method)
    customer = Appointments::Customer.for(activity)
    company = customer&.company
    when_text = Appointments::TimeText.for(activity, company)
    ics = invite.to_ics
    invite.recipients.each do |email, name, role|
      message = AppointmentInviteMailer.invite(activity_class, activity_id, email, name, method, ics, when_text, company&.id).deliver_now
      log_for_customer(activity, customer, email, Array(message&.from).first, method, when_text) if role == :customer
    rescue StandardError => e
      Rails.logger.warn("[AppointmentInviteJob] #{activity_class} #{activity_id} to #{email}: #{e.class}: #{e.message}")
    end
  end

  private

  # The customer's invite shows on their timeline like any email to them.
  def log_for_customer(activity, customer, email, from, method, when_text)
    Communication.create!(
      communicable: customer.record, channel: 'email', direction: 'outbound', status: 'sent', sent_at: Time.current,
      to_address: email, from_address: from.presence || customer.company&.email.presence || Brand.current(company: customer.company).from_email, subject: method == 'CANCEL' ? "Cancelled: #{activity.subject}" : "Calendar invite: #{activity.subject}",
      body: method == 'CANCEL' ? "Appointment cancelled: #{when_text}." : "Calendar invite sent for #{when_text}.",
      metadata: { 'source' => 'calendar_invite', 'activity_type' => activity.class.name, 'activity_id' => activity.id }
    )
  rescue StandardError => e
    Rails.logger.warn("[AppointmentInviteJob] log for #{activity.class.name} #{activity.id}: #{e.message}")
  end
end
