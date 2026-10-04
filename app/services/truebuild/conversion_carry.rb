# frozen_string_literal: true

module Truebuild
  # When a lead with saved designs is converted, the designs and the buyer's
  # portal login follow them: the login moves to the new contact (opening the
  # full portal), the designs point at the contact, account and deal, and an
  # empty deal takes the newest design's home and price.
  module ConversionCarry
    module_function

    def call(lead:, contact:, account:, deal:)
      designs = TruebuildDesign.where(company_id: lead.company_id, lead_id: lead.id)
      return 0 if designs.none?

      designs.update_all(contact_id: contact&.id, account_id: account&.id, deal_id: deal&.id, updated_at: Time.current)
      # Only a login with the contact's own email follows them: a login is a
      # person's, and a lead can have been merged with someone else's saves.
      if contact&.email.present?
        BuyerPortalAccess.where(buyer_type: 'Lead', buyer_id: lead.id).where('LOWER(email) = ?', contact.email.downcase)
                         .update_all(buyer_type: 'Contact', buyer_id: contact.id, updated_at: Time.current)
      end
      fill_deal(deal, designs.order(created_at: :desc).first) if deal
      designs.size
    end

    def fill_deal(deal, design)
      attrs = {}
      total = design.price_snapshot['show_prices'] ? design.price_snapshot['total'] : nil
      attrs[:value] = total if total && deal.value.to_f.zero?
      attrs[:vehicle_id] = design.vehicle_id if design.vehicle_id && deal.respond_to?(:vehicle_id) && deal.vehicle_id.nil?
      deal.update_columns(attrs.merge(updated_at: Time.current)) if attrs.any?
    end
  end
end
