# frozen_string_literal: true

# Calendar invites for appointments (Appointments::CalendarInvite). Everything
# here speaks for the rep the appointment is assigned to, not whoever booked
# it.
# - The customer's copy names the rep as organizer and is sent from the rep's
#   own mailbox when they have one connected (AppointmentInviteJob passes that
#   address as from).
# - The rep's copy is organized in the company's name so it lands on the rep's
#   calendar (calendars ignore invites the reader organized).
# The organizer address and Reply-To are the appointment's tracked reply
# address, so responses and notes come back through inbound mail to the rep.
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
    tracked = invite.reply_address
    ics =
      if @role == 'customer'
        invite.to_ics(organizer: [tracked, @rep_name || @company&.name || 'Your appointment'],
                      attendees: [[email, name], ([rep_address, @rep_name || rep_address] if rep_address.present?)].compact)
      else
        sender_name = (Mail::Address.new(sender.to_s).display_name rescue nil)
        invite.to_ics(organizer: [tracked, @company&.name || sender_name.presence || 'Appointments'],
                      attendees: [[email, name]])
      end

    attachments['invite.ics'] = { mime_type: "text/calendar; method=#{method}; charset=UTF-8", content: ics }
    mail(
      to: email,
      from: sender,
      reply_to: @role == 'customer' ? tracked : nil,
      subject: method == 'CANCEL' ? "Cancelled: #{@subject_line} (#{@when_text})" : "Appointment: #{@subject_line} (#{@when_text})"
    )
  end
end
