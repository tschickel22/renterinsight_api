# frozen_string_literal: true

class TwilioProvisioningService
  class ProvisioningError < StandardError; end

  def self.master_client
    Twilio::REST::Client.new(
      ENV['TWILIO_ACCOUNT_SID'],
      ENV['TWILIO_AUTH_TOKEN']
    )
  end

  def self.provision_client(company)
    Rails.logger.info "[TwilioProvisioning] Starting provisioning for Company #{company.id} (#{company.name})"

    if company.twilio_account&.active?
      Rails.logger.warn "[TwilioProvisioning] Company #{company.id} already has active TwilioAccount"
      return { success: false, error: 'Company already has an active Twilio account' }
    end

    if company.sms_provisioning_mode == 'disabled'
      return { success: false, error: 'SMS is disabled for this company' }
    end

    twilio_account = company.twilio_account || company.build_twilio_account(status: 'provisioning')

    begin
      sub_account = create_sub_account(company)
      Rails.logger.info "[TwilioProvisioning] Sub-account created: #{sub_account.sid}"

      twilio_account.sub_account_sid = sub_account.sid
      twilio_account.auth_token = sub_account.auth_token
      twilio_account.status = 'provisioning'
      twilio_account.phone_number_sid = 'pending'
      twilio_account.phone_number = '+10000000000'
      twilio_account.save!

      phone = purchase_phone_number(sub_account.sid, sub_account.auth_token)
      Rails.logger.info "[TwilioProvisioning] Phone number purchased: #{phone.phone_number} (#{phone.sid})"

      twilio_account.phone_number = phone.phone_number
      twilio_account.phone_number_sid = phone.sid
      twilio_account.save!

      configure_webhook(sub_account.sid, sub_account.auth_token, phone.sid)
      Rails.logger.info "[TwilioProvisioning] Webhook configured for #{phone.phone_number}"

      twilio_account.mark_active!
      company.update!(sms_provisioning_mode: 'dedicated')

      Rails.logger.info "[TwilioProvisioning] ✅ Provisioning complete for Company #{company.id}"

      {
        success: true,
        twilio_account: twilio_account,
        phone_number: phone.phone_number,
        sub_account_sid: sub_account.sid
      }

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
        release_phone_number(twilio_account.sub_account_sid, twilio_account.auth_token, twilio_account.phone_number_sid)
        Rails.logger.info "[TwilioProvisioning] Phone number released: #{twilio_account.phone_number}"
      end

      suspend_sub_account(twilio_account.sub_account_sid)
      Rails.logger.info "[TwilioProvisioning] Sub-account suspended: #{twilio_account.sub_account_sid}"

      twilio_account.mark_suspended!
      company.update!(sms_provisioning_mode: 'platform')

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

  def self.create_sub_account(company)
    friendly_name = "RI-#{company.id}-#{company.name.parameterize[0..20]}"
    master_client.api.accounts.create(friendly_name: friendly_name)
  end

  def self.purchase_phone_number(sub_account_sid, auth_token, area_code: nil)
    sub_client = Twilio::REST::Client.new(sub_account_sid, auth_token)

    search_params = { country: 'US', sms_enabled: true, voice_enabled: true }
    search_params[:area_code] = area_code if area_code.present?

    available = sub_client.api.available_phone_numbers('US').local.list(**search_params, limit: 1)
    raise ProvisioningError, "No phone numbers available#{area_code ? " for area code #{area_code}" : ''}" if available.empty?

    sub_client.api.incoming_phone_numbers.create(phone_number: available.first.phone_number)
  end

  def self.configure_webhook(sub_account_sid, auth_token, phone_number_sid)
    sub_client = Twilio::REST::Client.new(sub_account_sid, auth_token)
    api_base_url = ENV['API_BASE_URL'] || 'https://renterinsight-api-staging.onrender.com'

    sub_client.api.incoming_phone_numbers(phone_number_sid).update(
      sms_url: "#{api_base_url}/webhooks/twilio/sms/inbound",
      sms_method: 'POST'
    )
  end

  def self.release_phone_number(sub_account_sid, auth_token, phone_number_sid)
    sub_client = Twilio::REST::Client.new(sub_account_sid, auth_token)
    sub_client.api.incoming_phone_numbers(phone_number_sid).delete
  rescue Twilio::REST::RestError => e
    Rails.logger.warn "[TwilioProvisioning] Could not release phone number #{phone_number_sid}: #{e.message}"
  end

  def self.suspend_sub_account(sub_account_sid)
    master_client.api.accounts(sub_account_sid).update(status: 'suspended')
  end

  private_class_method :create_sub_account, :purchase_phone_number, :configure_webhook,
                       :release_phone_number, :suspend_sub_account
end
