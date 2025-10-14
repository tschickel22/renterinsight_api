# frozen_string_literal: true

module Api
  module Portal
    class PreferencesController < ApplicationController
      before_action :authenticate_portal_user!
      before_action :load_portal_access

      # GET /api/portal/preferences
      def show
        render json: {
          ok: true,
          preferences: {
            email_opt_in: @portal_access.email_opt_in,
            sms_opt_in: @portal_access.sms_opt_in,
            marketing_opt_in: @portal_access.marketing_opt_in,
            portal_enabled: @portal_access.portal_enabled
          }
        }, status: :ok
      end

      # PATCH /api/portal/preferences
      def update
        # Check raw params for portal_enabled before filtering
        if params[:preferences]&.key?(:portal_enabled) || params[:preferences]&.key?('portal_enabled')
          return render json: {
            ok: false,
            error: 'Cannot modify portal_enabled through API'
          }, status: :forbidden
        end

        # Handle empty or missing preferences
        prefs = safe_preference_params
        if prefs.empty?
          return render json: {
            ok: true,
            preferences: {
              email_opt_in: @portal_access.email_opt_in,
              sms_opt_in: @portal_access.sms_opt_in,
              marketing_opt_in: @portal_access.marketing_opt_in,
              portal_enabled: @portal_access.portal_enabled
            }
          }, status: :ok
        end

        # Validate boolean values
        unless valid_boolean_params?(prefs)
          return render json: {
            ok: false,
            error: 'Invalid preference values. Must be true or false.'
          }, status: :unprocessable_entity
        end

        if @portal_access.update(prefs)
          render json: {
            ok: true,
            preferences: {
              email_opt_in: @portal_access.email_opt_in,
              sms_opt_in: @portal_access.sms_opt_in,
              marketing_opt_in: @portal_access.marketing_opt_in,
              portal_enabled: @portal_access.portal_enabled
            }
          }, status: :ok
        else
          render json: {
            ok: false,
            error: @portal_access.errors.full_messages.join(', ')
          }, status: :unprocessable_entity
        end
      end

      # GET /api/portal/preferences/history
      def history
        changes = @portal_access.recent_preference_changes(50)

        render json: {
          ok: true,
          history: changes
        }, status: :ok
      end

      private

      def authenticate_portal_user!
        token = request.headers['Authorization']&.split(' ')&.last

        unless token
          return render json: {
            ok: false,
            error: 'Authentication required'
          }, status: :unauthorized
        end

        begin
          decoded = JWT.decode(token, Rails.application.secret_key_base, true, { algorithm: 'HS256' })
          @current_buyer_id = decoded[0]['buyer_id']
          @current_buyer_type = decoded[0]['buyer_type']
        rescue JWT::DecodeError, JWT::ExpiredSignature
          render json: {
            ok: false,
            error: 'Invalid or expired token'
          }, status: :unauthorized
        end
      end

      def load_portal_access
        @portal_access = BuyerPortalAccess.find_by(
          buyer_id: @current_buyer_id,
          buyer_type: @current_buyer_type
        )

        unless @portal_access
          render json: {
            ok: false,
            error: 'Portal access not found'
          }, status: :not_found
        end
      end

      def safe_preference_params
        return {} unless params[:preferences].is_a?(ActionController::Parameters) || params[:preferences].is_a?(Hash)
        
        params.require(:preferences).permit(:email_opt_in, :sms_opt_in, :marketing_opt_in).to_h
      rescue ActionController::ParameterMissing
        {}
      end

      def valid_boolean_params?(prefs)
        return true if prefs.empty?

        prefs.each do |key, value|
          # Check if value is a boolean or string representation of boolean
          unless [true, false, 'true', 'false'].include?(value)
            return false
          end
        end

        true
      end
    end
  end
end
