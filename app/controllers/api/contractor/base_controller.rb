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

          # Support both old (single ID) and new (multi ID) JWT format
          if payload['contractor_ids'].present?
            @contractor_ids = payload['contractor_ids']
            @primary_contractor_id = payload['primary_contractor_id'] || @contractor_ids.first
          elsif payload['contractor_id'].present?
            @contractor_ids = [payload['contractor_id']]
            @primary_contractor_id = payload['contractor_id']
          else
            return render json: { error: 'Invalid token' }, status: :unauthorized
          end

          @current_contractor = ::Contractor.find_by(id: @primary_contractor_id, is_deleted: [false, nil])

          unless @current_contractor
            return render json: { error: 'Invalid token' }, status: :unauthorized
          end

          unless @current_contractor.status == 'active'
            return render json: { error: 'Account is inactive' }, status: :forbidden
          end

          @all_contractors = ::Contractor.where(id: @contractor_ids, is_deleted: [false, nil], status: 'active')

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

      def all_contractors
        @all_contractors
      end

      def all_contractor_ids
        @contractor_ids
      end

      def parse_photos(raw)
        return [] unless raw.present?

        arr = if raw.is_a?(String)
          JSON.parse(raw) rescue []
        elsif raw.is_a?(Array)
          raw.map(&:to_s)
        else
          []
        end

        arr.select { |url| url.is_a?(String) && url.present? }
      end

      def extract_token_from_header
        header = request.headers['Authorization']
        return nil unless header
        header.split(' ').last if header.start_with?('Bearer ')
      end

      def self.generate_contractor_token(contractor)
        all_records = ::Contractor.where(
          email: contractor.email.downcase.strip,
          is_deleted: [false, nil],
          status: 'active'
        ).order(:created_at)

        contractor_ids = all_records.pluck(:id)
        primary_id = all_records.first&.id || contractor.id

        payload = {
          contractor_ids: contractor_ids,
          primary_contractor_id: primary_id,
          email: contractor.email,
          exp: 7.days.from_now.to_i
        }

        JWT.encode(payload, Rails.application.credentials.secret_key_base, 'HS256')
      end
    end
  end
end
