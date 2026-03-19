# frozen_string_literal: true

module Api
  module Contractor
    class SessionsController < ApplicationController
      skip_before_action :authenticate

      # POST /api/contractor/sessions/magic_link
      def magic_link
        contractor = ::Contractor.find_by(email: params[:email]&.downcase&.strip, is_deleted: [false, nil])

        if contractor && contractor.status == 'active'
          contractor.generate_portal_token!

          CommunicationService.send_email(
            communicable: contractor,
            to: contractor.email,
            subject: 'Your Contractor Portal Login Link',
            body: "Click the link below to access your contractor portal:\n\n" \
                  "Your login code: #{contractor.portal_access_token}\n\n" \
                  "This link expires in 30 minutes.",
            category: 'transactional'
          )
        end

        # Always return success to prevent email enumeration
        render json: {
          ok: true,
          message: 'If an account exists, a magic link has been sent'
        }, status: :ok
      end

      # POST /api/contractor/sessions/verify
      def verify
        contractor = ::Contractor.find_by(
          portal_access_token: params[:token],
          is_deleted: [false, nil]
        )

        if contractor&.portal_token_valid?(params[:token]) && contractor.status == 'active'
          contractor.update!(
            portal_access_token: nil,
            portal_token_expires_at: nil,
            last_portal_login_at: Time.current
          )

          token = Api::Contractor::BaseController.generate_contractor_token(contractor)

          render json: {
            success: true,
            token: token,
            user: {
              id: contractor.id,
              name: contractor.name,
              email: contractor.email,
              tradeType: contractor.trade_type,
              user_type: 'contractor'
            }
          }, status: :ok
        else
          render json: {
            success: false,
            error: 'Invalid or expired token'
          }, status: :unauthorized
        end
      end
    end
  end
end
