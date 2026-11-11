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

  # An item assigned to someone, sent when we tick "Email them now". Replies
  # go to whoever sent it.
  def assigned(user, item, sender)
    @user = user
    @item = item
    @sender = sender
    @brand = Brand.current
    @client = user.company_id == item.company_id
    @url = Onboarding::Checklist.item_link(item, user)
    mail(to: user.email, from: default_from_address, reply_to: sender&.email.presence,
         subject: @client ? "#{@brand.name} setup: #{item.title}" : "#{item.company.name}: #{item.title}")
  end

  # The intro to a client's setup plan (Onboarding::Intro). Replies go to
  # whoever sent it.
  def intro(user, company, sender, note)
    @user = user
    @company = company
    @sender = sender
    @note = note
    @brand = Brand.current
    @url = Onboarding::Intro.link
    mail(to: user.email, from: default_from_address, reply_to: sender&.email.presence,
         subject: "Your #{@brand.name} setup plan is ready")
  end
end
