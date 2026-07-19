# frozen_string_literal: true

class PasswordResetMailer < ApplicationMailer
  def reset_instructions(email:, token:, reset_url:, user_name: nil, email_settings: {})
    @user_name = user_name || 'User'
    @reset_url = reset_url
    @token = token
    @expires_in = '1 hour'

    # Get from email and name from settings
    from_email = email_settings['fromEmail'].presence || ENV['MAILER_FROM'].presence || brand.from_email
    from_name = email_settings['fromName'].presence || ENV['EMAIL_FROM_NAME'].presence || brand.from_name

    mail(
      to: email,
      from: "#{from_name} <#{from_email}>",
      subject: 'Reset Your Password'
    )
  end
end
