class ApplicationMailer < ActionMailer::Base
  layout 'mailer'

  private

  # Resolves the From: address for a mailer using a User → Location → Company → Platform waterfall.
  # Set @sender_user, @location, and/or @company in the mailer action to scope the lookup.
  # Returns nil if no level has a from_address configured so ActionMailer raises instead of
  # silently sending from a bogus noreply inbox.
  def default_from_address
    from_email = nil
    from_name  = nil

    # 1. User-level override (if any mailer has set @sender_user)
    if @sender_user.respond_to?(:id) && @sender_user.id.present?
      settings = Setting.get('User', @sender_user.id, 'communications')
      from_email, from_name = dig_email(settings)
    end

    # 2. Location
    if from_email.blank? && @location.respond_to?(:id) && @location.id.present?
      settings = Setting.get('Location', @location.id, 'communications')
      from_email, from_name = dig_email(settings)
    end

    # 3. Company
    if from_email.blank? && @company.respond_to?(:id) && @company.id.present?
      settings = Setting.get('Company', @company.id, 'communications')
      from_email, from_name = dig_email(settings)
    end

    # 4. Platform
    if from_email.blank?
      settings = Setting.get('Platform', 0, 'communications')
      from_email, from_name = dig_email(settings)
    end

    if from_email.blank?
      Rails.logger.warn "[ApplicationMailer] No from_address configured at User/Location/Company/Platform level — letting ActionMailer fall through to config.action_mailer defaults."
      return nil
    end

    from_name = from_name.presence || 'RenterInsight'
    "#{from_name} <#{from_email}>"
  end

  # Extract [from_address, from_name] from a communications settings hash,
  # tolerating string-keyed, symbol-keyed, or JSON-string values.
  def dig_email(settings)
    return [nil, nil] if settings.blank?
    hash = case settings
           when Hash   then settings.deep_stringify_keys
           when String then (JSON.parse(settings).deep_stringify_keys rescue {})
           else              {}
           end
    email_cfg = hash['email'].is_a?(Hash) ? hash['email'] : {}
    # Accept every historical variant: snake_case, camelCase, and the canonical
    # fromEmail / fromName used by the platform settings UI.
    from_address = email_cfg['from_address'].presence ||
                   email_cfg['fromAddress'].presence  ||
                   email_cfg['fromEmail'].presence    ||
                   email_cfg['from_email'].presence
    from_name    = email_cfg['from_name'].presence    ||
                   email_cfg['fromName'].presence
    [from_address, from_name]
  end
end
