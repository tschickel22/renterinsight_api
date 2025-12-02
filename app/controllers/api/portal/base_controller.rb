module Api
  module Portal
    class BaseController < ApplicationController
      skip_before_action :authenticate
      before_action :authenticate_portal_contact

      private

      def authenticate_portal_contact
        token = extract_token_from_header

        unless token
          return render json: { error: 'Missing authorization header' }, status: :unauthorized
        end

        begin
          decoded_token = JWT.decode(
            token,
            Rails.application.credentials.secret_key_base,
            true,
            { algorithm: 'HS256' }
          )

          payload = decoded_token.first
          contact_id = payload['contact_id']
          company_id = payload['company_id']

          @current_contact = Contact.find_by(id: contact_id, company_id: company_id)

          unless @current_contact
            return render json: { error: 'Invalid token' }, status: :unauthorized
          end

          # Check if contact is active (assuming there's an is_active or similar field)
          # Adjust this based on your actual Contact model
          unless @current_contact.respond_to?(:is_active?) ? @current_contact.is_active? : true
            return render json: { error: 'Account is inactive' }, status: :forbidden
          end

          # Set company context for tenant isolation
          @company = @current_contact.company
          Current.company = @company if defined?(Current)
          Current.company_id = @company.id if defined?(Current)

        rescue JWT::ExpiredSignature
          render json: { error: 'Token has expired' }, status: :unauthorized
        rescue JWT::DecodeError => e
          render json: { error: 'Invalid token' }, status: :unauthorized
        rescue => e
          Rails.logger.error "Portal authentication error: #{e.message}"
          render json: { error: 'Authentication failed' }, status: :unauthorized
        end
      end

      def current_contact
        @current_contact
      end

      def extract_token_from_header
        header = request.headers['Authorization']
        return nil unless header

        # Extract token from "Bearer <token>" format
        header.split(' ').last if header.start_with?('Bearer ')
      end

      # Helper to generate JWT token for contact (used in login)
      def self.generate_portal_token(contact)
        payload = {
          contact_id: contact.id,
          company_id: contact.company_id,
          email: contact.email,
          exp: 7.days.from_now.to_i
        }

        JWT.encode(payload, Rails.application.credentials.secret_key_base, 'HS256')
      end
    end
  end
end
