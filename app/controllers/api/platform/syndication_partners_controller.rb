# frozen_string_literal: true

module Api
  module Platform
    class SyndicationPartnersController < ApplicationController
      before_action :set_company
      before_action :set_partner, only: [:show, :update, :destroy, :toggle]

      # GET /api/platform/syndication-partners
      def index
        partners = @company.syndication_partners.order(created_at: :desc)
        
        render json: {
          partners: partners.map { |p| partner_json(p) }
        }
      end

      # GET /api/platform/syndication-partners/:id
      def show
        render json: { partner: partner_json(@partner, detailed: true) }
      end

      # POST /api/platform/syndication-partners
      def create
        partner = @company.syndication_partners.new(partner_params)

        if partner.save
          render json: { 
            partner: partner_json(partner, detailed: true),
            message: 'Syndication partner created successfully'
          }, status: :created
        else
          render json: { errors: partner.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/platform/syndication-partners/:id
      def update
        if @partner.update(partner_params)
          render json: { 
            partner: partner_json(@partner, detailed: true),
            message: 'Syndication partner updated successfully'
          }
        else
          render json: { errors: @partner.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/platform/syndication-partners/:id
      def destroy
        @partner.destroy
        render json: { message: 'Syndication partner deleted successfully' }
      end

      # PATCH /api/platform/syndication-partners/:id/toggle
      def toggle
        @partner.update!(active: !@partner.active)
        render json: { 
          partner: partner_json(@partner, detailed: true),
          message: @partner.active ? 'Partner activated' : 'Partner deactivated'
        }
      end

      private

      def set_company
        @company = ::Company.find_by(id: current_user.company_id)
        
        unless @company
          render json: { error: 'Company not found' }, status: :not_found
        end
      end

      def set_partner
        @partner = @company.syndication_partners.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Syndication partner not found' }, status: :not_found
      end

      def partner_params
        params.require(:partner).permit(
          :name,
          :partner_type,
          :format,
          :account_id,
          :api_key,
          :webhook_url,
          :active,
          listing_types: []
        )
      end

      def partner_json(partner, detailed: false)
        json = {
          id: partner.id.to_s,
          name: partner.name,
          partnerType: partner.partner_type,
          format: partner.format,
          listingTypes: partner.listing_types || [],
          accountId: partner.account_id,
          active: partner.active,
          feedUrl: partner.feed_url,
          createdAt: partner.created_at,
          updatedAt: partner.updated_at
        }

        if detailed
          json.merge!({
            apiKey: partner.api_key,
            webhookUrl: partner.webhook_url,
            feedToken: partner.feed_token,
            lastSyncedAt: partner.last_synced_at,
            syncStatus: partner.sync_status,
            syncError: partner.sync_error
          })
        end

        json
      end
    end
  end
end
