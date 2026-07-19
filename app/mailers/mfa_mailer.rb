# frozen_string_literal: true

class MfaMailer < ApplicationMailer
  def mfa_reset(email:, user_name:, reset_by:, company_name: nil, email_settings: nil)
    @user_name = user_name
    @reset_by = reset_by
    @company_name = company_name.presence || brand.name

    from_email = email_settings&.dig('fromEmail').presence || ENV['MAILER_FROM'].presence || brand.from_email
    from_name = email_settings&.dig('fromName').presence || ENV['EMAIL_FROM_NAME'].presence || brand.from_name

    mail(
      to: email,
      from: "#{from_name} <#{from_email}>",
      subject: 'Your Two-Factor Authentication Has Been Reset'
    )
  end

  def verification_code(email:, code:, user_name:, email_settings: nil)
    @code = code
    @user_name = user_name
    @expires_in = 5 # minutes

    # Configure sender from settings
    from_email = email_settings&.dig('fromEmail').presence || ENV['MAILER_FROM'].presence || brand.from_email
    from_name = email_settings&.dig('fromName').presence || ENV['EMAIL_FROM_NAME'].presence || brand.from_name

    mail(
      to: email,
      from: "#{from_name} <#{from_email}>",
      subject: 'Your Verification Code'
    )
  end
end
