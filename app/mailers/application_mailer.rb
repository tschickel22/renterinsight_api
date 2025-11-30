class ApplicationMailer < ActionMailer::Base
  layout 'mailer'

  private

  def default_from_address
    # Try to get from email from settings hierarchy: Location -> Company -> Platform
    from_email = nil
    from_name = nil

    # Try location settings first
    if @location.present?
      location_comms = Setting.get('communications', 'Location', @location.id)
      from_email = location_comms.dig('email', 'from_address') if location_comms.present?
      from_name = location_comms.dig('email', 'from_name') if location_comms.present?
    end

    # Fall back to company settings
    if from_email.blank? && @company.present?
      company_comms = Setting.get('communications', 'Company', @company.id)
      from_email = company_comms.dig('email', 'from_address') if company_comms.present?
      from_name = company_comms.dig('email', 'from_name') if company_comms.present?
    end

    # Fall back to platform settings
    if from_email.blank?
      platform_comms = Setting.get('communications', 'Platform', 0)
      from_email = platform_comms.dig('email', 'from_address') if platform_comms.present?
      from_name = platform_comms.dig('email', 'from_name') if platform_comms.present?
    end

    # Final fallback
    from_email ||= Rails.application.credentials.dig(:mailer_from) || 'noreply@renterinsight.com'
    from_name ||= 'RenterInsight'

    "#{from_name} <#{from_email}>"
  end
end
