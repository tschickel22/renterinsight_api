# frozen_string_literal: true

# The morning onboarding summary (Onboarding::DailySummary, backlog E97).
# System-facing, so it uses the platform brand.
class OnboardingMailer < ApplicationMailer
  # sections: [{ name:, company_id:, lines: [String], client: Boolean }]
  def daily(user, sections)
    @user = user
    @sections = sections
    @brand = Brand.current
    base = @brand.app_url.to_s.chomp('/')
    @client = sections.all? { |s| s[:client] }
    @url = @client ? "#{base}/?getting_started=1" : "#{base}/admin/onboarding"
    count = sections.sum { |s| s[:lines].size }
    subject = @client ? "Your #{@brand.name} setup: #{count} #{'update'.pluralize(count)}" : "Client onboarding: #{count} #{'update'.pluralize(count)} across #{sections.size} #{'client'.pluralize(sections.size)}"
    mail(to: user.email, from: default_from_address, subject: subject)
  end
end
