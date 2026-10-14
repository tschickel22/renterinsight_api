# frozen_string_literal: true

# Calendar invites for appointments (Appointments::CalendarInvite). The
# customer's copy is the dealership's, not the platform's: from the company's
# address, with replies going to the person they are meeting.
class AppointmentInviteMailer < ApplicationMailer
  def invite(activity_class, activity_id, email, name, method, ics, when_text, company_id)
    @company = Company.find_by(id: company_id)
    @activity = activity_class.constantize.find_by(id: activity_id)
    @name = name
    @method = method
    @when_text = when_text
    @subject_line = @activity&.subject
    @place = @activity&.meeting_location
    assignee = @activity&.assigned_to || @activity&.user
    @sender_user = assignee

    attachments['invite.ics'] = { mime_type: "text/calendar; method=#{method}; charset=UTF-8", content: ics }
    mail(
      to: email,
      from: default_from_address || (brand.from_email.present? ? "#{brand.from_name.presence || brand.name} <#{brand.from_email}>" : nil),
      reply_to: assignee&.email,
      subject: method == 'CANCEL' ? "Cancelled: #{@subject_line} (#{when_text})" : "Appointment: #{@subject_line} (#{when_text})"
    )
  end
end
