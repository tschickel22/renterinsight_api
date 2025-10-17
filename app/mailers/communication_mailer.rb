# frozen_string_literal: true

class CommunicationMailer < ApplicationMailer
  def send_communication(to:, subject:, body:, from_email:, from_name:, cc: nil, bcc: nil)
    mail(
      to: to,
      from: "#{from_name} <#{from_email}>",
      cc: cc,
      bcc: bcc,
      subject: subject
    ) do |format|
      if body&.include?('<html') || body&.include?('<body')
        format.html { render html: body.html_safe }
      else
        format.text { render plain: body }
      end
    end
  end
end
