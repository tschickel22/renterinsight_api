# frozen_string_literal: true

require 'net/http'

class SmsRegistration
  # Registers a dealer's own texting with the carriers through Twilio (E96
  # phase 4), as an ISV: a secondary customer profile and an A2P trust product
  # under our primary profile, a brand, the dealer's own Messaging Service, and
  # (once the brand is approved, by StatusPoller) the campaign and number.
  #
  # Every step records the SID it made and is skipped when run again, so a
  # failure part way can be fixed and the submit run again without creating a
  # second of anything. A rejected campaign is fixed and resubmitted, never
  # deleted and recreated.
  #
  # Runs only when a platform admin sends a registration: each brand and
  # campaign carries a vetting fee and the campaign a monthly fee.
  #
  # Not yet run against live Twilio (built 2026-11-07); the first real dealer
  # should be watched step by step.
  class Submitter
    class Error < StandardError; end

    # Twilio's policy for an ISV's secondary customer profile, and for the A2P
    # messaging profile (trust product).
    CUSTOMER_PROFILE_POLICY = 'RNdfbf3fae0e1107f8aded0e7cead80bf5'
    A2P_PROFILE_POLICY = 'RNb0d4771c2c98518d916a3d4cd70a8f8b'
    PRIMARY_PROFILE_ENV = 'TWILIO_PRIMARY_CUSTOMER_PROFILE_SID'
    # Renter Insight, LLC's primary customer profile on our Twilio account.
    DEFAULT_PRIMARY_PROFILE = 'BU22b45de7878e3eae80406bfa5ddf0f63'

    attr_reader :registration

    def initialize(registration, client: nil)
      @registration = registration
      @client = client
    end

    def call
      raise Error, 'Sole proprietor registrations are done in the Twilio Console for now.' if registration.sole_proprietor?

      problems = registration.problems
      raise Error, "Not ready: #{problems.join(', ')}" if problems.any?

      customer_profile!
      trust_product!
      brand!
      messaging_service!
      registration.update!(status: 'in_review', sent_to_carriers_at: registration.sent_to_carriers_at || Time.current)
      registration.log!('sent_to_carriers')
      registration
    rescue Twilio::REST::RestError, Error => e
      registration.update_columns(rejection_reason: e.message.truncate(1000), updated_at: Time.current)
      registration.log!('submit_failed', e.message.truncate(300))
      raise Error, e.message
    end

    # Called by StatusPoller once the brand is approved.
    def campaign!
      return if registration.campaign_status.present? && registration.campaign_status != 'FAILED'

      attrs = registration.campaign_content.twilio_attributes.merge('BrandRegistrationSid' => registration.brand_registration_sid)
      path = "/v1/Services/#{registration.messaging_service_sid}/Compliance/Usa2p"
      # A failed campaign is updated in place (Twilio allows edits only then).
      path += "/#{CAMPAIGN_COMPLIANCE_SID}" if registration.campaign_status == 'FAILED'
      body = rest_post('https://messaging.twilio.com', path, attrs)
      registration.update!(campaign_status: body['campaign_status'] || 'IN_PROGRESS')
      registration.log!('campaign_submitted')
    end

    # The SID Twilio uses for every service's A2P compliance record.
    CAMPAIGN_COMPLIANCE_SID = 'QE2c6890da8086d771620e9b13fadeba0b'

    # Called by StatusPoller once the campaign is VERIFIED: a number in the
    # dealer's area code, on their Messaging Service, as their TwilioAccount.
    def number!
      return registration.company.twilio_accounts.active.first if registration.phone_number.present?

      area = registration.preferred_area_code.presence || registration.contact['phone'].to_s.gsub(/\D/, '').last(10)[0, 3]
      available = client.available_phone_numbers('US').local.list(area_code: area, sms_enabled: true, limit: 1).first
      available ||= client.available_phone_numbers('US').local.list(in_region: registration.business['state'], sms_enabled: true, limit: 1).first
      raise Error, "No numbers available in #{area} or #{registration.business['state']}" unless available

      bought = client.incoming_phone_numbers.create(phone_number: available.phone_number,
                                                    friendly_name: "#{registration.dealer_name} (own texting)")
      client.messaging.v1.services(registration.messaging_service_sid).phone_numbers.create(phone_number_sid: bought.sid)
      registration.update!(phone_number: bought.phone_number, phone_number_sid: bought.sid)
      account = TwilioAccount.create!(
        company_id: registration.company_id, phone_number: bought.phone_number, phone_number_sid: bought.sid,
        status: 'active', provisioned_at: Time.current,
        metadata: { 'own_registration' => true, 'messaging_service_sid' => registration.messaging_service_sid,
                    'links_allowed' => true, 'sms_registration_id' => registration.id }
      )
      registration.log!('number_bought', bought.phone_number)
      account
    end

    private

    def client
      @client ||= TwilioProvisioningService.master_client
    end

    def primary_profile_sid
      ENV[PRIMARY_PROFILE_ENV].presence || DEFAULT_PRIMARY_PROFILE
    end

    def b = registration.business
    def c = registration.contact

    def notify_email
      Brand.current.support_email
    end

    def customer_profile!
      return if registration.customer_profile_sid.present?

      trusthub = client.trusthub.v1
      profile = trusthub.customer_profiles.create(friendly_name: "#{b['legal_name']} (#{registration.company_id})",
                                                  email: notify_email, policy_sid: CUSTOMER_PROFILE_POLICY)
      business = trusthub.end_users.create(
        friendly_name: "#{b['legal_name']} business", type: 'customer_profile_business_information',
        attributes: {
          business_name: b['legal_name'], business_identity: 'direct_customer', business_type: b['business_type'],
          business_industry: b['industry'].presence || 'REAL_ESTATE', business_registration_identifier: 'EIN',
          business_registration_number: b['ein'], business_regions_of_operation: 'USA_AND_CANADA',
          website_url: b['website'], social_media_profile_urls: ''
        }
      )
      rep = trusthub.end_users.create(
        friendly_name: "#{c['first_name']} #{c['last_name']}", type: 'authorized_representative_1',
        attributes: { first_name: c['first_name'], last_name: c['last_name'], email: c['email'],
                      phone_number: e164(c['phone']), business_title: c['title'], job_position: 'Other' }
      )
      address = client.addresses.create(customer_name: b['legal_name'], street: b['street'], city: b['city'],
                                        region: b['state'], postal_code: b['zip'], iso_country: 'US')
      document = trusthub.supporting_documents.create(friendly_name: "#{b['legal_name']} address", type: 'customer_profile_address',
                                                      attributes: { address_sids: address.sid })
      assignments = trusthub.customer_profiles(profile.sid).customer_profiles_entity_assignments
      [business.sid, rep.sid, document.sid, primary_profile_sid].each { |sid| assignments.create(object_sid: sid) }
      evaluation = trusthub.customer_profiles(profile.sid).customer_profiles_evaluations.create(policy_sid: CUSTOMER_PROFILE_POLICY)
      raise Error, "Business profile incomplete: #{evaluation_errors(evaluation)}" unless evaluation.status == 'compliant'

      trusthub.customer_profiles(profile.sid).update(status: 'pending-review')
      registration.update!(customer_profile_sid: profile.sid, end_user_sid: business.sid, address_sid: address.sid)
      registration.log!('business_profile_submitted', profile.sid)
    end

    def trust_product!
      return if registration.trust_product_sid.present?

      trusthub = client.trusthub.v1
      product = trusthub.trust_products.create(friendly_name: "#{b['legal_name']} A2P", email: notify_email,
                                               policy_sid: A2P_PROFILE_POLICY)
      info = trusthub.end_users.create(friendly_name: "#{b['legal_name']} messaging profile",
                                       type: 'us_a2p_messaging_profile_information',
                                       attributes: { company_type: 'private' })
      assignments = trusthub.trust_products(product.sid).trust_products_entity_assignments
      [info.sid, registration.customer_profile_sid].each { |sid| assignments.create(object_sid: sid) }
      evaluation = trusthub.trust_products(product.sid).trust_products_evaluations.create(policy_sid: A2P_PROFILE_POLICY)
      raise Error, "Messaging profile incomplete: #{evaluation_errors(evaluation)}" unless evaluation.status == 'compliant'

      trusthub.trust_products(product.sid).update(status: 'pending-review')
      registration.update!(trust_product_sid: product.sid)
      registration.log!('messaging_profile_submitted', product.sid)
    end

    def brand!
      return if registration.brand_registration_sid.present?

      brand = client.messaging.v1.brand_registrations.create(
        customer_profile_bundle_sid: registration.customer_profile_sid,
        a2p_profile_bundle_sid: registration.trust_product_sid,
        skip_automatic_sec_vet: registration.brand_type == 'low_volume_standard'
      )
      registration.update!(brand_registration_sid: brand.sid, brand_status: brand.status)
      registration.log!('brand_submitted', brand.sid)
    end

    def messaging_service!
      return if registration.messaging_service_sid.present?

      base = TwilioProvisioningService.api_base_url
      service = client.messaging.v1.services.create(
        friendly_name: "#{registration.dealer_name} (#{registration.company_id})",
        inbound_request_url: "#{base}/webhooks/twilio/sms/inbound", status_callback: "#{base}/webhooks/twilio/sms/status",
        use_inbound_webhook_on_number: false, sticky_sender: true
      )
      registration.update!(messaging_service_sid: service.sid)
      registration.log!('messaging_service_created', service.sid)
    end

    def evaluation_errors(evaluation)
      Array(evaluation.results).flat_map { |r| Array(r['fields']).reject { |f| f['passed'] }.map { |f| f['friendly_name'] || f['object_field'] } }
                               .compact.uniq.join(', ').presence || evaluation.status
    end

    def e164(phone)
      digits = phone.to_s.gsub(/\D/, '')
      digits = "1#{digits}" if digits.length == 10
      "+#{digits}"
    end

    # Twilio REST, form-encoded, repeating array keys (MessageSamples).
    def rest_post(host, path, attrs)
      sid, token = TwilioProvisioningService.master_credentials
      uri = URI("#{host}#{path}")
      req = Net::HTTP::Post.new(uri)
      req.basic_auth(sid, token)
      req.set_form_data(attrs.flat_map { |k, v| Array(v).map { |x| [k, x.to_s] } })
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
      body = JSON.parse(res.body) rescue {}
      raise Error, "Twilio #{res.code}: #{body['message'] || res.body.to_s.truncate(200)}" unless res.code.to_i.between?(200, 299)

      body
    end
  end
end
