# frozen_string_literal: true

module Truebuild
  # A buyer who saves a design gets a portal login there and then, so they can
  # sign in later (magic link, or set a password) even if they never open the
  # email, from the portal sign in or the main app sign in.
  #
  # Only for a lead with that same email: intake matches leads by phone too,
  # so a save with someone else's phone can be absorbed into THEIR lead, and a
  # login then would hang another person's records off the saver's email.
  # Signing in always proves the inbox (an emailed link, or a reset), so a
  # login made for an email someone typed shows nothing to whoever typed it.
  # What it can still do: portal emails are unique platform-wide, so a save
  # at one dealer with a stranger's email holds that email there, and that
  # person's own save at another dealer then gets no login (state
  # exists_at_another_dealer). Accepted (Tom, 2026-10-01): rare, and the
  # dealer still gets the lead.
  #
  # The emailed link (claim!) signs the buyer straight in.
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

      # An existing login gets a sign in link; a new one the claim link,
      # which signs them straight in (they have no password yet).
      BuyerPortalMailer.truebuild_design_email(design, access: access).deliver_later
      created = access ? nil : create_for(design)
      note(design, access ? 'existing' : 'created', access || created)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      note(design, 'invited')
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
