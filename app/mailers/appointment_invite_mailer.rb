# frozen_string_literal: true

# Calendar invites for appointments (Appointments::CalendarInvite). Everything
# here speaks for the rep the appointment is assigned to, not whoever booked
# it.
# - The customer's copy is organized by the rep, replies go to the rep, and it
#   is sent from the rep's own mailbox when they have one connected
#   (AppointmentInviteJob passes that address as from).
# - The rep's copy is organized by the company's address so it lands on the
#   rep's calendar (calendars ignore invites the reader organized).
class AppointmentInviteMailer < ApplicationMailer
  def invite(activity_class, activity_id, email, name, method, role, company_id, from: nil, rep_id: nil)
    @company = Company.find_by(id: company_id)
    @activity = activity_class.constantize.find_by(id: activity_id)
    invite = Appointments::CalendarInvite.new(@activity, method: method)
    rep = rep_id ? User.find_by(id: rep_id) : invite.assignee
    @name = name
    @method = method
    @role = role.to_s
    @rep_name = rep.try(:full_name).presence
    @customer_name = invite.customer&.name
    @when_text = Appointments::TimeText.for(@activity, @company)
    @subject_line = @activity&.subject
    @place = invite.place
    @sender_user = rep if @role == 'customer'

    sender = from.presence || default_from_address ||
             (brand.from_email.present? ? "#{brand.from_name.presence || brand.name} <#{brand.from_email}>" : nil)
    rep_address = from.present? ? Mail::Address.new(from).address : rep&.email
    ics =
      if @role == 'customer'
        invite.to_ics(organizer: [rep_address, @rep_name || rep_address],
                      attendees: [[email, name], ([rep_address, @rep_name || rep_address] if rep_address.present?)].compact)
      else
        organizer = Mail::Address.new(sender.to_s)
        invite.to_ics(organizer: [organizer.address, organizer.display_name.presence || @company&.name || organizer.address],
                      attendees: [[email, name]])
      end

    attachments['invite.ics'] = { mime_type: "text/calendar; method=#{method}; charset=UTF-8", content: ics }
    mail(
      to: email,
      from: sender,
      reply_to: @role == 'customer' ? rep_address : nil,
      subject: method == 'CANCEL' ? "Cancelled: #{@subject_line} (#{@when_text})" : "Appointment: #{@subject_line} (#{@when_text})"
    )
  end
end
