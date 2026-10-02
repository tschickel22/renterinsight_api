# frozen_string_literal: true

# Tells a dealership's admins that AI Apps (the Claude connector and the
# DealerTide plugin) is now on for their account, how to install it and what
# to ask. Sent once per admin when the admin.ai_connector add-on is switched
# on. Platform-branded: it comes from the platform, not the dealership.
class AiConnectorMailer < ApplicationMailer
  layout 'branded_mailer'

  # The DealerTide plugin in Claude's directory (connector plus skills).
  # CLAUDE_PLUGIN_DIRECTORY_URL overrides it if the listing ever moves.
  DIRECTORY_URL = 'https://claude.ai/customize/plugins/id/acda747f-bac8-4859-8784-6a4d3ae0c4d4%40anthropic-plugin-directory'

  def self.directory_url
    ENV['CLAUDE_PLUGIN_DIRECTORY_URL'].presence || DIRECTORY_URL
  end

  def enabled(company_id, user_id)
    @company = Company.find_by(id: company_id)
    @user = @company&.users&.find_by(id: user_id)
    return if @company.nil? || @user.nil? || @user.email.blank?

    @brand = Brand.current
    branding = (PlatformSetting.branding || {}).to_h.with_indifferent_access
    @brand_primary = branding[:primaryColor].presence || '#0F2A52'
    @brand_accent = branding[:secondaryColor].presence || '#00AFA8'
    @brand_font = "#{branding[:fontFamily].presence || 'Poppins'}, -apple-system, 'Segoe UI', Arial, sans-serif"
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
