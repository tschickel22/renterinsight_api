# frozen_string_literal: true

module Api
  module Portal
    # Inherits BaseController for portal auth. It previously subclassed
    # ApplicationController directly, which meant the global
    # `before_action :authenticate` was never skipped AND its own auth verified
    # against Rails.application.secret_key_base while every token is signed with
    # JsonWebToken (ENV['JWT_SECRET']). Both layers rejected, so every request
    # here 401'd regardless of credentials.
    class PreferencesController < BaseController
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

      # BaseController has already resolved and authorized the portal session,
      # so the access record comes straight from it rather than being looked up
      # again from token claims.
      def load_portal_access
        @portal_access = current_buyer_access

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
