# frozen_string_literal: true

# Shared handling for credentials inside `communications` settings, which are
# stored at three scopes (Platform, Company, Location) and were each carrying
# their own copy of this logic. The copies drifted, and the platform one lost
# the real Twilio auth token on every save — see restore_masked_secrets.
#
# The read/write contract:
#   read  → mask_sensitive_fields  replaces stored secrets with MASKED_PLACEHOLDER
#   write → restore_masked_secrets swaps a mask/blank/already-encrypted value
#           back for what is in the DB, so only a genuinely new secret is taken
#   write → encrypt_sensitive_fields enciphers whatever survived that
module CommunicationSecrets
  extend ActiveSupport::Concern

  MASKED_PLACEHOLDER = '••••••••'

  # Any field sent back as a run of mask characters counts as "unchanged". The
  # FE has rendered masks of several lengths over time (a fixed 8 bullets, and
  # one dot per character of the stored value), so match the shape, not a length.
  MASK_ONLY_REGEX = /\A[•\*●·∙ ]+\z/

  SENSITIVE_KEYS = {
    'email' => %w[smtpPassword gmailClientSecret gmailRefreshToken sendgridApiKey awsSecretAccessKey],
    'sms'   => %w[twilioAuthToken awsSecretAccessKey]
  }.freeze

  private

  # Settings arrive as ActionController::Parameters, which is NOT a Hash — so
  # `is_a?(Hash)` guards silently fell through while `dig` kept working, and the
  # mask reached encrypt() and replaced the real credential. Normalize at the
  # boundary so nothing downstream has to know the difference.
  def normalize_settings_payload(settings)
    case settings
    when ActionController::Parameters then settings.to_unsafe_h.deep_stringify_keys
    when Hash then settings.deep_stringify_keys
    else settings
    end
  end

  def mask_only?(value)
    str = value.to_s
    str == MASKED_PLACEHOLDER || MASK_ONLY_REGEX.match?(str)
  end

  # Replace stored secrets with a placeholder before sending settings to a client.
  def mask_sensitive_fields(settings)
    return settings unless settings.is_a?(Hash)

    masked = settings.deep_dup
    SENSITIVE_KEYS.each do |section, keys|
      sub = masked[section] || masked[section.to_sym]
      next unless sub.is_a?(Hash)

      keys.each do |key|
        k = sub.key?(key) ? key : key.to_sym
        sub[k] = MASKED_PLACEHOLDER if sub[k].present?
      end
    end

    masked
  end

  # Swap incoming placeholders for the secrets already on file.
  def restore_masked_secrets(settings, existing)
    restored = normalize_settings_payload(settings)
    return restored unless restored.is_a?(Hash) && existing.is_a?(Hash)

    SENSITIVE_KEYS.each do |section, keys|
      next unless restored[section].is_a?(Hash)

      keys.each do |key|
        # Absent means removed: a section the client sent is authoritative, so
        # omitting a secret key deletes it (that is how switching email provider
        # drops a stale SMTP password). Clients that mean "keep this" must send
        # the mask back, not drop the field.
        next unless restored[section].key?(key)

        value          = restored[section][key].to_s
        existing_value = existing.dig(section, key) || existing.dig(section.to_sym, key.to_sym)

        # A blank field means the form never carried the secret, not "erase it" —
        # there is no clear-secret affordance in the UI, so treating blank as an
        # erase is a second way to silently lose credentials.
        next unless mask_only?(value) || value.start_with?('encrypted:') || value.blank?

        if existing_value.present?
          restored[section][key] = existing_value
        elsif mask_only?(value)
          # Nothing to fall back on — drop the key rather than encipher a run of
          # bullets and store it as though it were a credential.
          restored[section].delete(key)
        end
      end
    end

    restored
  end

  def encrypt_sensitive_fields(settings)
    encrypted = normalize_settings_payload(settings)
    return encrypted unless encrypted.is_a?(Hash)

    SENSITIVE_KEYS.each do |section, keys|
      next unless encrypted[section].is_a?(Hash)

      keys.each do |key|
        value = encrypted[section][key]
        encrypted[section][key] = encrypt_secret(value) if value.present?
      end
    end

    encrypted
  end

  def encrypt_secret(value)
    return value if value.blank?
    return value if value.to_s.start_with?('encrypted:')

    # Belt and braces: a display mask is never a credential. Reaching here means
    # restore_masked_secrets was bypassed — refuse loudly rather than encipher
    # bullets and take SMS down for every tenant on this scope.
    if mask_only?(value)
      Rails.logger.error '[CommunicationSecrets] refused to encrypt a masked placeholder as a secret'
      return nil
    end

    "encrypted:#{secret_encryptor.encrypt_and_sign(value.to_s)}"
  end

  def decrypt_secret(value)
    return value unless value.is_a?(String) && value.start_with?('encrypted:')

    secret_encryptor.decrypt_and_verify(value.sub('encrypted:', ''))
  rescue StandardError => e
    Rails.logger.error "[CommunicationSecrets] decrypt failed: #{e.message}"
    nil
  end

  def secret_encryptor
    key_base = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
    key = ActiveSupport::KeyGenerator.new(key_base).generate_key('', 32)
    ActiveSupport::MessageEncryptor.new(key)
  end
end
