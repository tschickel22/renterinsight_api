# frozen_string_literal: true

module Api
  module V1
    # Dealer side of listing syndication (Company Settings, Listing Partners).
    #
    # Partners are platform-level: platform admins add them and switch them on
    # or off (Api::Platform::SyndicationPartnersController), and each feed
    # carries every dealer's published listings. A dealer cannot add, remove
    # or switch a partner. What a dealer can do here is save its own account
    # number with a partner site, which the feed then sends as the dealer
    # identifier on that dealer's listings only.
    #
    # SyndicationPartner rows are deliberately not looked up through @company:
    # they belong to the platform, and this controller exposes only their
    # name, type and on/off state (never the feed URL or token).
    class ListingPartnersController < ApplicationController
      before_action :set_company_scope
      before_action :set_partner, only: [:update]

      # GET /api/v1/listing_partners
      def index
        return unless authorize_action!('company_settings', 'read')

        ids = SyndicationPartner.dealer_account_ids_for(@company.id)
        partners = SyndicationPartner.order(:name)

        brand = Brand.current
        render json: {
          partners: partners.map { |p| partner_json(p, ids[p.id.to_s]) },
          platformName: brand.name,
          supportEmail: brand.support_email,
          canEdit: can_edit?
        }
      end

      # PATCH /api/v1/listing_partners/:id
      # Body: { dealer_account_id: "..." } (blank clears it)
      def update
        unless can_edit?
          return render json: { error: 'Only company administrators can change listing partner settings' },
                        status: :forbidden
        end

        if params[:dealer_account_id].to_s.strip.present? && !@partner.sends_dealer_account_id?
          return render json: { error: "#{@partner.name} does not use your account number" },
                        status: :unprocessable_entity
        end

        value = @partner.set_dealer_account_id!(@company, params[:dealer_account_id])
        render json: { partner: partner_json(@partner, value) }
      end

      private

      def set_partner
        @partner = SyndicationPartner.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def can_edit?
        current_user.effective_admin?
      end

      def partner_json(partner, dealer_account_id)
        {
          id: partner.id.to_s,
          name: partner.name,
          partnerType: partner.partner_type,
          listingTypes: partner.listing_types || [],
          sends: partner.dealer_sends,
          usesAccountNumber: partner.sends_dealer_account_id?,
          active: partner.active?,
          dealerAccountId: (dealer_account_id.presence if partner.sends_dealer_account_id?)
        }
      end
    end
  end
end
