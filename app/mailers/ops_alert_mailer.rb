# frozen_string_literal: true

# Tells the platform owner a server is in trouble (Ops::Alert). System-facing,
# so it uses the platform brand. The from address does not touch the
# database: this also has to send when the database is the problem.
class OpsAlertMailer < ApplicationMailer
  def alert(to, subject, body)
    @body = body
    mail(to: to, from: ENV['MAILER_FROM'].presence || (Brand.current.from_email rescue nil) || 'noreply@dealertide.com', subject: subject)
  end
end
