# frozen_string_literal: true

module Truebuild
  # A signed, short-lived "this is that buyer" for the designer on the
  # dealer's website. The designer runs on the dealer's site (often its own
  # domain) and cannot see the buyer's portal session, so a design opened
  # from My Designs carries one; saving with it goes straight to the buyer's
  # account, with no contact form and no new lead.
  module BuyerPass
    module_function

    TTL = 12.hours

    def issue(access)
      verifier.generate({ 'a' => access.id, 'c' => access.company_id }, expires_in: TTL, purpose: :truebuild_buyer)
    end

    # The portal login the pass names, if it is valid for this dealer.
    def resolve(token, company)
      data = token.present? && verifier.verified(token.to_s, purpose: :truebuild_buyer)
      return nil unless data.is_a?(Hash) && data['c'] == company.id

      access = BuyerPortalAccess.find_by(id: data['a'], company_id: company.id)
      access if access&.portal_enabled != false && access&.buyer
    end

    def verifier
      Rails.application.message_verifier('truebuild_buyer_pass')
    end
  end
end
