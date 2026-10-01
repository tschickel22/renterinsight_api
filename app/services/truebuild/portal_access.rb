# frozen_string_literal: true

module Truebuild
  # A buyer who saves a design is invited to a portal login, so their designs
  # are waiting and the dealer sees their logins and returns.
  #
  # The login is created only when the buyer clicks the link we email them
  # (claim!), never at save time, and only for a lead with that same email:
  #   * intake matches leads by phone too, so a save with someone else's
  #     phone can be absorbed into THEIR lead; a login made then would hang
  #     another person's records off the saver's email.
  #   * portal emails are unique platform-wide, so a login made from an
  #     anonymous save would let anyone reserve a stranger's email.
  # Clicking proves the inbox is theirs; the email check proves the lead is.
  #
  # The login belongs to the lead until the rep converts it (it then moves to
  # the contact, see ConversionCarry). A lead-level login sees My Designs and a
  # few buyer-scoped pages only.
  module PortalAccess
    module_function

    CLAIM_TTL = 7.days
    PURPOSE = :truebuild_portal_claim

    def call(design)
      return note(design, 'no_lead') unless design.lead && design.buyer_email.present?
      return note(design, 'lead_email_mismatch') unless same_email?(design.lead.email, design.buyer_email)

      access = existing(design.buyer_email)
      return note(design, 'exists_at_another_dealer') if access && access.company_id != design.company_id
      return note(design, 'disabled') if access && !access.portal_enabled

      BuyerPortalMailer.truebuild_design_email(design, access: access).deliver_later
      note(design, access ? 'existing' : 'invited', access)
    end

    def claim_token(design)
      verifier.generate(design.id, expires_in: CLAIM_TTL, purpose: PURPOSE)
    end

    # The buyer clicked the emailed link: their login, created now if needed.
    # Nil when the link is bad or expired or the design no longer qualifies.
    def claim!(token)
      design = TruebuildDesign.find_by(id: verifier.verified(token.to_s, purpose: PURPOSE))
      return nil unless design&.lead && same_email?(design.lead.email, design.buyer_email)

      access = existing(design.buyer_email)
      return nil if access && (access.company_id != design.company_id || !access.portal_enabled)

      access ||= create_for(design)
      note(design, 'claimed', access)
      access
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      nil
    end

    def create_for(design)
      password = SecureRandom.alphanumeric(24)
      BuyerPortalAccess.create!(
        buyer: design.lead, company_id: design.company_id, email: design.buyer_email.downcase,
        password: password, password_confirmation: password, portal_enabled: true,
        email_opt_in: true, sms_opt_in: false, marketing_opt_in: false, status: 'Active', role: 'Client'
      )
    end

    def existing(email)
      BuyerPortalAccess.find_by('LOWER(email) = ?', email.to_s.downcase)
    end

    def same_email?(a, b)
      a.present? && b.present? && a.to_s.strip.casecmp?(b.to_s.strip)
    end

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end

    def note(design, state, access = nil)
      design.update_columns(metadata: design.metadata.merge('portal' => { 'state' => state, 'access_id' => access&.id }.compact))
      access
    end
  end
end
