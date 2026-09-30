# frozen_string_literal: true

module Truebuild
  # A buyer who saves a design gets a portal login, so their designs are
  # waiting for them and the dealer sees their logins and returns.
  #
  # The login belongs to the lead until the rep converts it (it then moves to
  # the contact, see ConversionCarry). A lead-level login sees My Homes only:
  # the rest of the portal (quotes, invoices, documents) belongs to contacts.
  #
  # Portal logins are unique by email across the platform. A buyer who already
  # has one at this dealer gets a sign-in link; one at another dealer is left
  # alone and the design notes why.
  module PortalAccess
    module_function

    LINK_TTL = 7.days

    def call(design)
      return unless design.lead && design.buyer_email.present?

      access = BuyerPortalAccess.find_by('LOWER(email) = ?', design.buyer_email.downcase)
      if access && access.company_id != design.company_id
        return note(design, 'exists_at_another_dealer')
      end

      created = access.nil?
      access ||= create_for(design)
      return note(design, 'disabled') unless access.portal_enabled

      if created
        access.update!(login_token: SecureRandom.urlsafe_base64(32), login_token_expires_at: LINK_TTL.from_now)
      end
      BuyerPortalMailer.truebuild_design_email(access, design, magic: created).deliver_later
      note(design, created ? 'created' : 'existing', access)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      Rails.logger.warn("[Truebuild::PortalAccess] design #{design.id}: #{e.message}")
      note(design, 'failed')
    end

    def create_for(design)
      password = SecureRandom.alphanumeric(24)
      BuyerPortalAccess.create!(
        buyer: design.lead, company_id: design.company_id, email: design.buyer_email.downcase,
        password: password, password_confirmation: password, portal_enabled: true,
        email_opt_in: true, sms_opt_in: false, marketing_opt_in: false, status: 'Active', role: 'Client'
      )
    end

    def note(design, state, access = nil)
      design.update_columns(metadata: design.metadata.merge('portal' => { 'state' => state, 'access_id' => access&.id }.compact))
      access
    end
  end
end
