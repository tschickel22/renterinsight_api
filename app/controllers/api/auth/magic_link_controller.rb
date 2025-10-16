# frozen_string_literal: true

module Api
  module Auth
    class MagicLinkController < ApplicationController
      skip_before_action :authenticate, only: [:request_magic_link, :verify_magic_link]

      # POST /api/auth/request_magic_link
      def request_magic_link
        email = params[:email]&.downcase&.strip

        if email.blank?
          render json: {
            success: false,
            error: 'Email is required'
          }, status: :bad_request
          return
        end

        # Try to find user in either table
        user = find_user_by_email(email)

        if user
          # Generate token and send email
          generate_and_send_magic_link(user)
          
          render json: {
            success: true,
            message: 'Magic link sent to your email'
          }, status: :ok
        else
          # Security: Don't reveal if user exists or not
          render json: {
            success: true,
            message: 'If an account exists, a magic link has been sent'
          }, status: :ok
        end
      rescue StandardError => e
        Rails.logger.error("Magic link request error: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: {
          success: false,
          error: 'An error occurred. Please try again later.'
        }, status: :internal_server_error
      end

      # GET /api/auth/verify_magic_link
      def verify_magic_link
        token = params[:token]

        if token.blank?
          render json: {
            success: false,
            error: 'Token is required'
          }, status: :bad_request
          return
        end

        # Try to find token in either table
        user = find_user_by_token(token)

        if user && token_valid?(user)
          # Clear the token
          clear_magic_link_token(user)
          
          # Generate JWT
          jwt_token = generate_jwt(user)
          
          render json: {
            success: true,
            token: jwt_token,
            user: user_payload(user)
          }, status: :ok
        else
          render json: {
            success: false,
            error: 'Invalid or expired magic link'
          }, status: :unauthorized
        end
      rescue StandardError => e
        Rails.logger.error("Magic link verification error: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: {
          success: false,
          error: 'Failed to verify magic link. Please try again.'
        }, status: :internal_server_error
      end

      private

      def find_user_by_email(email)
        # Try admin/staff users first
        user = User.find_by(email: email)
        return { type: 'User', record: user } if user

        # Try client portal users
        buyer_access = BuyerPortalAccess.find_by(email: email)
        return { type: 'BuyerPortalAccess', record: buyer_access } if buyer_access

        nil
      end

      def find_user_by_token(token)
        # Try admin/staff users first
        user = User.find_by(magic_link_token: token)
        return { type: 'User', record: user } if user

        # Try client portal users
        buyer_access = BuyerPortalAccess.find_by(login_token: token)
        return { type: 'BuyerPortalAccess', record: buyer_access } if buyer_access

        nil
      end

      def generate_and_send_magic_link(user_data)
        user_type = user_data[:type]
        record = user_data[:record]

        if user_type == 'User'
          # Admin/Staff user
          token = SecureRandom.urlsafe_base64(32)
          record.update!(
            magic_link_token: token,
            magic_link_expires_at: 15.minutes.from_now
          )
          
          MagicLinkMailer.admin_magic_link(record, token).deliver_now
          Rails.logger.info("[MagicLinkController] Magic link sent to admin: #{record.email}")
        else
          # Client portal user
          record.generate_login_token
          BuyerPortalService.send_magic_link_email(record)
          Rails.logger.info("[MagicLinkController] Magic link sent to client: #{record.email}")
        end
      end

      def token_valid?(user_data)
        record = user_data[:record]
        user_type = user_data[:type]

        if user_type == 'User'
          # Admin user token validation
          record.magic_link_expires_at && record.magic_link_expires_at > Time.current
        else
          # Client portal user token validation
          record.login_token_valid?
        end
      end

      def clear_magic_link_token(user_data)
        record = user_data[:record]
        user_type = user_data[:type]

        if user_type == 'User'
          record.update!(magic_link_token: nil, magic_link_expires_at: nil)
        else
          record.update!(login_token: nil, login_token_expires_at: nil)
        end
      end

      def generate_jwt(user_data)
        record = user_data[:record]
        user_type = user_data[:type]

        if user_type == 'User'
          # Admin/Staff JWT
          JsonWebToken.encode(user_id: record.id)
        else
          # Client portal JWT
          JsonWebToken.encode(buyer_portal_access_id: record.id)
        end
      end

      def user_payload(user_data)
        record = user_data[:record]
        user_type = user_data[:type]

        if user_type == 'User'
          # Admin/Staff user payload
          {
            id: record.id,
            email: record.email,
            firstName: record.first_name,
            lastName: record.last_name,
            role: record.role,
            user_type: 'admin'
          }
        else
          # Client portal user payload
          {
            id: record.id,
            email: record.email,
            buyer_type: record.buyer_type,
            buyer_id: record.buyer_id,
            user_type: 'client',
            role: 'client'
          }
        end
      end
    end
  end
end
