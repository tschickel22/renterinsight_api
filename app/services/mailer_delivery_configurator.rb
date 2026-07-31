# frozen_string_literal: true

# Resolves the correct ActionMailer delivery method + options for a "system"
# mailer (approval emails, notifications, etc.) that fires from background
# jobs rather than a controller. Reads the effective platform/company/location
# communications Settings, decrypts sensitive fields, and returns a hash that
# can be passed directly to `mail(delivery_method:, delivery_method_options:)`.
#
# Returns nil if no usable provider is configured — caller should let
# ActionMailer fall back to whatever the environment default is.
class MailerDeliveryConfigurator
  class << self
    # @param company [Company, nil]
    # @param location [Location, nil]
    # @return [Hash{Symbol => Object}, nil] {
    #   delivery_method: Symbol,
    #   delivery_method_options: Hash,
    #   from_address: String,
    #   from_name: String
    # }
    def resolve(company: nil, location: nil)
      ensure_custom_delivery_methods_registered!

      email_cfg = effective_email_config(company: company, location: location)
      return nil if email_cfg.blank?

      provider = (email_cfg['provider'] || email_cfg[:provider] || 'smtp').to_s

      case provider
      when 'aws_ses'
        build_ses(email_cfg)
      when 'smtp', 'gmail'
        build_smtp(email_cfg, oauth: false)
      when 'oauth_google'
        build_smtp(email_cfg, oauth: true, default_host: 'smtp.gmail.com')
      when 'oauth_microsoft'
        build_smtp(email_cfg, oauth: true, default_host: 'smtp.office365.com')
      when 'sendgrid'
        build_sendgrid(email_cfg)
      else
        Rails.logger.warn "[MailerDeliveryConfigurator] Unknown provider '#{provider}', skipping override"
        nil
      end
    end

    # Registers :aws_ses_sdk on ActionMailer if it's missing. Safe to call many
    # times. Required in dev/test where Rails reloaders can wipe
    # ActionMailer::Base.delivery_methods between requests even though the boot
    # initializer added it.
    def ensure_custom_delivery_methods_registered!
      return if ActionMailer::Base.delivery_methods.key?(:aws_ses_sdk)

      require Rails.root.join('lib', 'aws_ses_delivery').to_s unless defined?(AwsSesDelivery)
      ActionMailer::Base.add_delivery_method(:aws_ses_sdk, AwsSesDelivery)
    rescue LoadError, NameError => e
      Rails.logger.error "[MailerDeliveryConfigurator] could not register :aws_ses_sdk — #{e.class}: #{e.message}"
    end

    private

    def effective_email_config(company:, location:)
      platform = load_settings('Platform', 0)
      merged   = (platform['email'] || platform[:email] || {}).deep_stringify_keys

      if company&.id
        company_cfg = load_settings('Company', company.id)
        merged = merged.merge((company_cfg['email'] || company_cfg[:email] || {}).deep_stringify_keys) { |_, v1, v2| v2.presence || v1 }
      end

      if location&.id
        loc_cfg = load_settings('Location', location.id)
        merged = merged.merge((loc_cfg['email'] || loc_cfg[:email] || {}).deep_stringify_keys) { |_, v1, v2| v2.presence || v1 }
      end

      decrypt_sensitive(merged)
    end

    def load_settings(scope_type, scope_id)
      raw = Setting.get(scope_type, scope_id, 'communications')
      case raw
      when Hash   then raw.deep_stringify_keys
      when String then (JSON.parse(raw).deep_stringify_keys rescue {})
      else              {}
      end
    end

    SENSITIVE_FIELDS = %w[
      smtpPassword gmailClientSecret gmailRefreshToken sendgridApiKey
      awsSecretAccessKey oauthAccessToken oauthRefreshToken
    ].freeze

    def decrypt_sensitive(cfg)
      out = cfg.deep_dup
      SENSITIVE_FIELDS.each do |key|
        val = out[key]
        next unless val.is_a?(String) && val.start_with?('encrypted:')
        # Falling back to `val` handed the raw ciphertext to the provider as if
        # it were the credential, which SES reports as SignatureDoesNotMatch and
        # sends you hunting a secret that was never wrong. Drop it instead so
        # the caller's own ENV fallback can supply a coherent credential.
        out[key] = decrypt(val.sub('encrypted:', ''))
      end
      out
    end

    def decrypt(ciphertext)
      secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
      key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
      ActiveSupport::MessageEncryptor.new(key).decrypt_and_verify(ciphertext)
    rescue => e
      Rails.logger.error "[MailerDeliveryConfigurator] decrypt failed: #{e.message}"
      nil
    end

    # --- provider builders ---

    def build_ses(cfg)
      access = cfg['awsAccessKeyId'].presence || cfg['aws_access_key_id']
      secret = cfg['awsSecretAccessKey'].presence || cfg['aws_secret_access_key']
      region = cfg['awsRegion'].presence || cfg['aws_region'] || 'us-east-1'
      return nil if access.blank? || secret.blank?

      # Pass the class directly rather than the :aws_ses_sdk symbol so ActionMailer
      # skips its per-subclass delivery_methods registry — that registry can be
      # out of sync in dev/async contexts depending on autoload order.
      require Rails.root.join('lib', 'aws_ses_delivery').to_s unless defined?(AwsSesDelivery)

      {
        delivery_method:         AwsSesDelivery,
        delivery_method_options: { access_key_id: access, secret_access_key: secret, region: region },
        from_address:            from_of(cfg),
        from_name:               name_of(cfg)
      }
    end

    def build_smtp(cfg, oauth: false, default_host: 'smtp.gmail.com')
      host     = cfg['smtpHost'].presence || default_host
      port     = (cfg['smtpPort'] || 587).to_i
      username = oauth ? cfg['oauthEmail'] : cfg['smtpUsername']
      password = oauth ? cfg['oauthAccessToken'] : cfg['smtpPassword']
      auth     = oauth ? :xoauth2 : (cfg['smtpAuthentication'].presence || 'plain').to_sym
      return nil if username.blank? || password.blank?

      {
        delivery_method: :smtp,
        delivery_method_options: {
          address:              host,
          port:                 port,
          user_name:            username,
          password:             password,
          authentication:       auth,
          enable_starttls_auto: true
        },
        from_address: from_of(cfg),
        from_name:    name_of(cfg)
      }
    end

    def build_sendgrid(cfg)
      api_key = cfg['sendgridApiKey']
      return nil if api_key.blank?

      {
        delivery_method: :smtp,
        delivery_method_options: {
          address:              'smtp.sendgrid.net',
          port:                 587,
          user_name:            'apikey',
          password:             api_key,
          authentication:       :plain,
          enable_starttls_auto: true
        },
        from_address: from_of(cfg),
        from_name:    name_of(cfg)
      }
    end

    def from_of(cfg)
      cfg['fromEmail'].presence ||
        cfg['from_email'].presence ||
        cfg['fromAddress'].presence ||
        cfg['from_address'].presence
    end

    def name_of(cfg)
      cfg['fromName'].presence || cfg['from_name'].presence
    end
  end
end
