# frozen_string_literal: true

module Api
  module Contractor
    class BaseController < ApplicationController
      skip_before_action :authenticate
      before_action :authenticate_contractor!

      private

      def authenticate_contractor!
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
          contractor_id = payload['contractor_id']

          @current_contractor = ::Contractor.find_by(id: contractor_id, is_deleted: [false, nil])

          unless @current_contractor
            return render json: { error: 'Invalid token' }, status: :unauthorized
          end

          unless @current_contractor.status == 'active'
            return render json: { error: 'Account is inactive' }, status: :forbidden
          end

        rescue JWT::ExpiredSignature
          render json: { error: 'Token has expired' }, status: :unauthorized
        rescue JWT::DecodeError
          render json: { error: 'Invalid token' }, status: :unauthorized
        rescue => e
          Rails.logger.error "Contractor authentication error: #{e.message}"
          render json: { error: 'Authentication failed' }, status: :unauthorized
        end
      end

      def current_contractor
        @current_contractor
      end

      def extract_token_from_header
        header = request.headers['Authorization']
        return nil unless header
        header.split(' ').last if header.start_with?('Bearer ')
      end

      def self.generate_contractor_token(contractor)
        payload = {
          contractor_id: contractor.id,
          email: contractor.email,
          exp: 7.days.from_now.to_i
        }

        JWT.encode(payload, Rails.application.credentials.secret_key_base, 'HS256')
      end
    end
  end
end
