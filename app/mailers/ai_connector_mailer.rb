# frozen_string_literal: true

# Tells a dealership's admins that AI Apps (the Claude connector and the
# DealerTide plugin) is now on for their account, how to install it and what
# to ask. Sent once per admin when the admin.ai_connector add-on is switched
# on. Platform-branded: it comes from the platform, not the dealership.
class AiConnectorMailer < ApplicationMailer
  # The plugin's listing in Claude's directory, when set. The email always
  # gives the click path (Customize, Plugins, Discover); this adds a direct
  # link.
  def self.directory_url
    ENV['CLAUDE_PLUGIN_DIRECTORY_URL'].presence
  end

  def enabled(company_id, user_id)
    @company = Company.find_by(id: company_id)
    @user = @company&.users&.find_by(id: user_id)
    return if @company.nil? || @user.nil? || @user.email.blank?

    @brand = Brand.current
    app = Brand.app_url.to_s.chomp('/')
    @ai_apps_url = "#{app}/settings?tab=ai-apps"
    @roles_url = "#{app}/settings?tab=users"
    @docs_url = "#{@brand.website_url.to_s.chomp('/')}/ai-connector/"
    @directory_url = self.class.directory_url

    from_email = ENV['MAILER_FROM'].presence || @brand.from_email
    from_name = ENV['EMAIL_FROM_NAME'].presence || @brand.from_name
    mail(to: @user.email, from: "#{from_name} <#{from_email}>",
         subject: "#{@brand.name} now works with Claude for #{@company.name}")
  end
end
