# frozen_string_literal: true

class SmsRegistration
  # Follows registrations the carriers are reviewing (E96 phase 4): records
  # brand and campaign status, submits the campaign once the brand is
  # approved, buys the number once the campaign is verified, and marks a
  # rejection with the carriers' reason. Runs every 30 minutes.
  class StatusPoller
    def self.run
      SmsRegistration.where(status: %w[in_review approved]).find_each { |r| new(r).call }
    end

    def initialize(registration, client: nil)
      @registration = registration
      @client = client
    end

    def call
      r = @registration
      submitter = Submitter.new(r, client: client)

      if r.brand_registration_sid.present? && r.brand_status != 'APPROVED'
        brand = client.messaging.v1.brand_registrations(r.brand_registration_sid).fetch
        r.update!(brand_status: brand.status)
        return reject!("Business not verified: #{Array(brand.failure_reason).join('; ').presence || brand.status}") if brand.status == 'FAILED'
        return unless brand.status == 'APPROVED'

        r.log!('brand_approved')
      end

      submitter.campaign! if r.brand_status == 'APPROVED' && r.campaign_status.blank?

      if r.campaign_status.present? && r.campaign_status != 'VERIFIED'
        campaign = client.messaging.v1.services(r.messaging_service_sid).us_app_to_person(Submitter::CAMPAIGN_COMPLIANCE_SID).fetch
        r.update!(campaign_status: campaign.campaign_status, campaign_id: campaign.campaign_id)
        if campaign.campaign_status == 'FAILED'
          reasons = Array(campaign.errors).map { |e| e['description'] }.compact.join(' ')
          return reject!("Texting not approved: #{reasons.presence || 'see Twilio'}")
        end
        return unless campaign.campaign_status == 'VERIFIED'

        r.update!(status: 'approved', approved_at: Time.current)
        r.log!('campaign_verified', campaign.campaign_id)
      end

      return unless r.campaign_status == 'VERIFIED' && r.phone_number.blank?

      submitter.number!
      # Live, with one caution from 2026-08-26: a new number can be dropped by
      # T-Mobile while Twilio reports delivered. Platform admin sends a test
      # text to a T-Mobile handset before telling the dealer (CLAUDE.md).
      r.update!(status: 'live', live_at: Time.current)
      r.log!('live', r.phone_number)
      r.notify_platform_admins!("#{r.dealer_name} is approved and has its number #{r.phone_number}. " \
                                'Send a test text to a T-Mobile phone before telling the dealer.')
    rescue StandardError => e
      Rails.logger.error("[SmsRegistration::StatusPoller] registration #{@registration.id}: #{e.class}: #{e.message}")
      @registration.log!('poll_failed', e.message.truncate(300))
    end

    private

    def client
      @client ||= TwilioProvisioningService.master_client
    end

    def reject!(reason)
      @registration.update!(status: 'rejected', rejection_reason: reason.truncate(1000))
      @registration.log!('rejected', reason.truncate(300))
      @registration.notify_platform_admins!("#{@registration.dealer_name}'s texting registration was turned down. #{reason.truncate(200)}")
    end
  end
end
