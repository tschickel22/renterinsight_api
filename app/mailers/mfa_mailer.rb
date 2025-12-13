# frozen_string_literal: true

class MfaMailer < ApplicationMailer
  def verification_code(email:, code:, user_name:, email_settings: nil)
    @code = code
    @user_name = user_name
    @expires_in = 5 # minutes

    # Configure sender from settings
    from_email = email_settings&.dig('fromEmail') || ENV['MAILER_FROM'] || 'noreply@renterinsight.com'
    from_name = email_settings&.dig('fromName') || ENV['EMAIL_FROM_NAME'] || 'RenterInsight'

    mail(
      to: email,
      from: "#{from_name} <#{from_email}>",
      subject: 'Your Verification Code'
    )
  end
end
