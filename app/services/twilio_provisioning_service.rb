# frozen_string_literal: true

# TwilioProvisioningService
#
# Architecture: numbers are purchased directly on the MASTER Twilio account.
# This means every dedicated number is automatically part of the master's A2P
# 10DLC registration and can be enrolled in the master's Messaging Service.
#
# Previous approach (sub-accounts) was abandoned because phone numbers owned
# by a sub-account cannot be enrolled in the master account's Messaging Service,
# making A2P compliance impossible without per-sub-account registration (~$4-8/mo each).
#
class TwilioProvisioningService
  class ProvisioningError < StandardError; end

  class AreaCodeUnavailableError < StandardError
    attr_reader :area_code
    def initialize(area_code)
      @area_code = area_code
      super("No available numbers for area code #{area_code}")
    end
  end

  # ─── Credentials & client ───────────────────────────────────────────────────

  def self.master_credentials
    sid   = ENV['TWILIO_ACCOUNT_SID'].presence
    token = ENV['TWILIO_AUTH_TOKEN'].presence

    unless sid && token
      sms = PlatformSetting.communications.dig(:sms) ||
            PlatformSetting.communications.dig('sms') || {}
      sid   ||= sms[:twilioAccountSid].presence || sms['twilioAccountSid'].presence
      raw   = sms[:twilioAuthToken].presence   || sms['twilioAuthToken'].presence
      token ||= decrypt_setting(raw)
    end

    raise ProvisioningError, 'Twilio master credentials not configured. Set TWILIO_ACCOUNT_SID / TWILIO_AUTH_TOKEN env vars or configure them in Platform Settings > Communications > SMS.' unless sid && token

    [sid, token]
  end

  def self.master_client
    sid, token = master_credentials
    Twilio::REST::Client.new(sid, token)
  end

  def self.messaging_service_sid
    sms_settings = Setting.get('Platform', 0, 'communications')&.dig('sms') || {}
    ENV['TWILIO_MESSAGING_SERVICE_SID'] ||
      sms_settings['twilioMessagingServiceSid'].presence ||
      sms_settings[:twilioMessagingServiceSid].presence
  end

  # ─── Public API ─────────────────────────────────────────────────────────────

  def self.provision_client(company, area_code: nil, country: 'US')
    Rails.logger.info "[TwilioProvisioning] Starting provisioning for Company #{company.id} (#{company.name})"

    if company.twilio_account&.active?
      return { success: false, error: 'Company already has an active Twilio account' }
    end

    if company.sms_provisioning_mode == 'disabled'
      return { success: false, error: 'SMS is disabled for this company' }
    end

    # Clean up any stale DB record (release the old number too if still owned)
    if (stale = company.twilio_account) && !stale.active?
      Rails.logger.info "[TwilioProvisioning] Clearing stale #{stale.status} TwilioAccount for Company #{company.id}"
      release_phone_number_from_master(stale.phone_number_sid) if stale.phone_number_sid.present? && stale.phone_number_sid != 'pending'
      stale.destroy!
    end

    twilio_account = company.build_twilio_account(
      status:           'provisioning',
      phone_number:     '+10000000000',
      phone_number_sid: 'pending'
    )

    begin
      phone = purchase_phone_number(area_code: area_code, country: country)
      Rails.logger.info "[TwilioProvisioning] Phone number purchased on master: #{phone.phone_number} (#{phone.sid})"

      twilio_account.phone_number     = phone.phone_number
      twilio_account.phone_number_sid = phone.sid
      twilio_account.save!

      configure_webhook_on_master(phone.sid)
      Rails.logger.info "[TwilioProvisioning] Webhook configured for #{phone.phone_number}"

      enroll_in_messaging_service(phone.sid, phone.phone_number)

      twilio_account.mark_active!
      company.update!(sms_provisioning_mode: 'dedicated')
      write_company_sms_settings(company, phone.phone_number)

      Rails.logger.info "[TwilioProvisioning] ✅ Provisioning complete for Company #{company.id} — #{phone.phone_number}"

      {
        success:       true,
        twilio_account: twilio_account,
        phone_number:  phone.phone_number
      }

    rescue AreaCodeUnavailableError => e
      # Release any number if somehow purchased before error
      twilio_account.destroy if twilio_account.persisted?
      { success: false, error: e.message, error_code: 'area_code_unavailable', area_code: e.area_code }

    rescue Twilio::REST::RestError => e
      error_msg = "Twilio API error: #{e.message} (code: #{e.code})"
      Rails.logger.error "[TwilioProvisioning] ❌ #{error_msg}"
      twilio_account.mark_failed!(error_msg) if twilio_account.persisted?
      { success: false, error: error_msg }

    rescue => e
      error_msg = "Provisioning failed: #{e.message}"
      Rails.logger.error "[TwilioProvisioning] ❌ #{error_msg}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      twilio_account.mark_failed!(error_msg) if twilio_account.persisted?
      { success: false, error: error_msg }
    end
  end

  def self.deprovision_client(company)
    Rails.logger.info "[TwilioProvisioning] Starting deprovision for Company #{company.id}"

    twilio_account = company.twilio_account
    unless twilio_account
      return { success: false, error: 'No Twilio account found for this company' }
    end

    begin
      if twilio_account.phone_number_sid.present? && twilio_account.phone_number_sid != 'pending'
        release_phone_number_from_master(twilio_account.phone_number_sid)
        Rails.logger.info "[TwilioProvisioning] Phone number released: #{twilio_account.phone_number}"
      end

      twilio_account.destroy!
      company.update!(sms_provisioning_mode: 'platform')
      clear_company_sms_settings(company)

      Rails.logger.info "[TwilioProvisioning] ✅ Deprovision complete for Company #{company.id}"
      { success: true }

    rescue Twilio::REST::RestError => e
      error_msg = "Twilio API error during deprovision: #{e.message}"
      Rails.logger.error "[TwilioProvisioning] ❌ #{error_msg}"
      { success: false, error: error_msg }

    rescue => e
      error_msg = "Deprovision failed: #{e.message}"
      Rails.logger.error "[TwilioProvisioning] ❌ #{error_msg}"
      { success: false, error: error_msg }
    end
  end

  # ─── Private helpers ────────────────────────────────────────────────────────

  def self.purchase_phone_number(area_code: nil, country: 'US')
    search_params = { sms_enabled: true, voice_enabled: true }
    search_params[:area_code] = area_code if area_code.present? && country == 'US'

    available = master_client.api.available_phone_numbers(country)
                             .local
                             .list(**search_params, limit: 1)

    if available.empty? && area_code.present?
      raise AreaCodeUnavailableError, area_code
    elsif available.empty?
      raise ProvisioningError, "No phone numbers are currently available in #{country}. Please try again later."
    end

    master_client.api.incoming_phone_numbers.create(phone_number: available.first.phone_number)
  end

  def self.configure_webhook_on_master(phone_number_sid)
    api_base_url = ENV['API_BASE_URL'] || 'https://renterinsight-api-staging.onrender.com'

    master_client.api.incoming_phone_numbers(phone_number_sid).update(
      sms_url:    "#{api_base_url}/webhooks/twilio/sms/inbound",
      sms_method: 'POST'
    )
  end

  def self.enroll_in_messaging_service(phone_number_sid, phone_number)
    sid = messaging_service_sid
    unless sid.present?
      Rails.logger.warn "[TwilioProvisioning] No MessagingServiceSid configured — #{phone_number} NOT enrolled in A2P sender pool"
      return
    end

    master_client.messaging.v1.services(sid).phone_numbers.create(phone_number_sid: phone_number_sid)
    Rails.logger.info "[TwilioProvisioning] ✅ Enrolled #{phone_number} in Messaging Service #{sid}"
  rescue => e
    # Non-fatal — provisioning still succeeds; operator can enroll manually
    Rails.logger.warn "[TwilioProvisioning] ⚠️ Could not enroll #{phone_number} in Messaging Service: #{e.message}"
  end

  def self.release_phone_number_from_master(phone_number_sid)
    master_client.api.incoming_phone_numbers(phone_number_sid).delete
  rescue Twilio::REST::RestError => e
    Rails.logger.warn "[TwilioProvisioning] Could not release phone number #{phone_number_sid}: #{e.message}"
  end

  # Write master-account number into company-level SMS settings so the
  # Location → Company → Platform waterfall resolves to the right number.
  # No auth credentials needed — CommunicationService uses master creds when
  # sms_provisioning_mode == 'dedicated'.
  def self.write_company_sms_settings(company, phone_number)
    master_sid, _token = master_credentials

    existing = Setting.get('Company', company.id, 'communications') || {}
    existing = existing.deep_stringify_keys

    existing['sms'] = {
      'provider'         => 'twilio',
      'isEnabled'        => true,
      'fromNumber'       => phone_number,
      'twilioAccountSid' => master_sid   # same master account — included for clarity
    }

    existing['_sources'] ||= {}
    existing['_sources']['sms'] = 'company'

    Setting.set('Company', company.id, 'communications', existing)
    Rails.logger.info "[TwilioProvisioning] Company #{company.id} SMS settings written (number: #{phone_number})"
  end

  def self.clear_company_sms_settings(company)
    existing = Setting.get('Company', company.id, 'communications') || {}
    existing = existing.deep_stringify_keys
    existing.delete('sms')
    existing['_sources']&.delete('sms')

    if existing.empty?
      Setting.delete_setting('Company', company.id, 'communications')
    else
      Setting.set('Company', company.id, 'communications', existing)
    end

    Rails.logger.info "[TwilioProvisioning] Company #{company.id} SMS settings cleared (reverted to platform)"
  end

  def self.decrypt_setting(value)
    return value if value.blank?
    return value unless value.start_with?('encrypted:')

    secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
    key  = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
    crypt = ActiveSupport::MessageEncryptor.new(key)
    crypt.decrypt_and_verify(value.sub('encrypted:', ''))
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature => e
    Rails.logger.error "[TwilioProvisioning] Failed to decrypt credential: #{e.message}"
    nil
  end

  def self.encrypt_setting(value)
    return value if value.blank?
    return value if value.start_with?('encrypted:')

    secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
    key   = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
    crypt = ActiveSupport::MessageEncryptor.new(key)
    "encrypted:#{crypt.encrypt_and_sign(value)}"
  end

  private_class_method :purchase_phone_number, :configure_webhook_on_master,
                       :enroll_in_messaging_service, :release_phone_number_from_master,
                       :decrypt_setting, :encrypt_setting,
                       :write_company_sms_settings, :clear_company_sms_settings
end
