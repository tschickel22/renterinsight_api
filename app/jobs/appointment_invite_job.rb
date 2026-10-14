# frozen_string_literal: true

# Sends (or updates, or cancels) an appointment's calendar invite. Delivered
# synchronously inside the job so a failure is logged against the attempt.
#
# The customer's copy goes from the assigned rep's own mailbox when one is
# connected, falling back to the company address with replies to the rep.
# former_user_id: a rep taken off the appointment, who gets only a CANCEL.
class AppointmentInviteJob < ApplicationJob
  queue_as :default

  def perform(activity_class, activity_id, method = 'REQUEST', former_user_id = nil)
    activity = activity_class.constantize.find_by(id: activity_id)
    return unless activity && activity.activity_type == 'meeting' && activity.start_time

    invite = Appointments::CalendarInvite.new(activity, method: method)
    customer = invite.customer
    company = customer&.company || activity.try(:deal)&.company
    when_text = Appointments::TimeText.for(activity, company)

    if former_user_id
      former = User.find_by(id: former_user_id)
      return unless former&.email.present?

      return deliver(activity_class, activity_id, former.email, former.try(:full_name), 'CANCEL', :rep, company, former)
    end

    rep = invite.assignee
    invite.recipients.each do |email, name, role, _user|
      from = deliver(activity_class, activity_id, email, name, method, role, company, rep)
      log_for_customer(activity, customer, email, from, method, when_text) if role == :customer && from
    end
  end

  private

  # Returns the From it went out under, or nil when it could not be sent.
  def deliver(activity_class, activity_id, email, name, method, role, company, rep)
    if role == :customer && (conn = Appointments::RepMailbox.connection_for(rep))
      from = Appointments::RepMailbox.from_for(rep, conn)
      message = AppointmentInviteMailer.invite(activity_class, activity_id, email, name, method, role.to_s, company&.id,
                                               from: from, rep_id: rep&.id).message
      return from if Appointments::RepMailbox.deliver(message, conn)
    end

    message = AppointmentInviteMailer.invite(activity_class, activity_id, email, name, method, role.to_s, company&.id,
                                             rep_id: rep&.id).deliver_now
    Array(message&.from).first || ''
  rescue StandardError => e
    Rails.logger.warn("[AppointmentInviteJob] #{activity_class} #{activity_id} to #{email}: #{e.class}: #{e.message}")
    nil
  end

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
