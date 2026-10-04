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

    # Who saves with a pass from a buyer's own first save (no account yet).
    Saver = Struct.new(:buyer, :email)

    # From a portal login (My Designs links).
    def issue(access)
      verifier.generate({ 'a' => access.id, 'c' => access.company_id }, expires_in: TTL, purpose: :truebuild_buyer)
    end

    # From a buyer's first save on the site, so saving another version asks
    # for nothing again. Handed only to whoever just saved, in that response.
    def issue_for_design(design)
      return nil unless design.lead_id

      verifier.generate({ 'l' => design.lead_id, 'c' => design.company_id, 'e' => design.buyer_email },
                        expires_in: TTL, purpose: :truebuild_buyer)
    end

    # The buyer the pass names (a portal login, or the lead and email of a
    # first save), if it is valid for this dealer.
    def resolve(token, company)
      data = token.present? && verifier.verified(token.to_s, purpose: :truebuild_buyer)
      return nil unless data.is_a?(Hash) && data['c'] == company.id

      if data['a']
        access = BuyerPortalAccess.find_by(id: data['a'], company_id: company.id)
        access if access&.portal_enabled != false && access&.buyer
      elsif data['l'] && (lead = company.leads.find_by(id: data['l']))
        Saver.new(lead, data['e'])
      end
    end

    def verifier
      Rails.application.message_verifier('truebuild_buyer_pass')
    end
  end
end
