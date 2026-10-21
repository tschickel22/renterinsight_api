# frozen_string_literal: true

module Api
  module V1
    # The dealer approves or declines an installer's rate card; the installer
    # can withdraw one still waiting (E68 step 6).
    class LinkRateCardsController < ApplicationController
      include LinkPricingJson

      before_action :set_company_scope
      before_action :set_card

      # POST /api/v1/link_rate_cards/:id/approve
      def approve
        return unless authorize_action!('vendors', 'update')

        render json: { rate_card: rate_card_json(service.approve!(@card)) }
      rescue LinkRateCardService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/link_rate_cards/:id/decline { reason }
      def decline
        return unless authorize_action!('vendors', 'update')

        render json: { rate_card: rate_card_json(service.decline!(@card, reason: params[:reason])) }
      rescue LinkRateCardService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/link_rate_cards/:id/withdraw
      def withdraw
        return render(json: { error: 'Only an admin can withdraw a rate card' }, status: :forbidden) unless current_user.effective_admin?

        render json: { rate_card: rate_card_json(service.withdraw!(@card)) }
      rescue LinkRateCardService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def service
        LinkRateCardService.new(@company, actor: current_user)
      end

      # Only a card on a link this company is part of.
      def set_card
        @card = LinkRateCard.joins(:company_link)
                            .where(company_links: { dealer_company_id: @company.id })
                            .or(LinkRateCard.joins(:company_link).where(company_links: { installer_company_id: @company.id }))
                            .find_by(id: params[:id])
        render json: { error: 'Not found' }, status: :not_found unless @card
      end
    end
  end
end
