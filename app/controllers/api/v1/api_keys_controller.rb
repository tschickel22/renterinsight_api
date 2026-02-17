# frozen_string_literal: true

module Api
  module V1
    class ApiKeysController < ApplicationController
      before_action :set_company_scope
      before_action :set_api_key, only: [:show, :update, :destroy, :revoke]

      # GET /api/v1/api-keys
      def index
        return unless authorize_action!("api_keys", "read")

        api_keys = @company.api_keys.order(created_at: :desc)

        render json: {
          api_keys: api_keys.map { |k| api_key_json(k) },
          meta: {
            total: api_keys.count,
            company_id: @company.id
          }
        }
      end

      # GET /api/v1/api-keys/:id
      def show
        return unless authorize_action!("api_keys", "read")

        render json: {
          api_key: api_key_json(@api_key, detailed: true)
        }
      end

      # POST /api/v1/api-keys
      def create
        return unless authorize_action!("api_keys", "create")

        api_key = @company.api_keys.new(api_key_params)
        api_key.created_by_user_id = current_user.id

        if api_key.save
          # Return the raw secret ONCE — it cannot be retrieved again
          json = api_key_json(api_key, detailed: true)
          json[:key] = api_key.key
          json[:secret] = api_key.raw_secret

          render json: {
            api_key: json,
            message: "API key created. Save the secret now — it will not be shown again."
          }, status: :created
        else
          render json: { errors: api_key.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/api-keys/:id
      def update
        return unless authorize_action!("api_keys", "update")

        if @api_key.update(api_key_update_params)
          render json: {
            api_key: api_key_json(@api_key, detailed: true),
            message: "API key updated successfully"
          }
        else
          render json: { errors: @api_key.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/api-keys/:id
      def destroy
        return unless authorize_action!("api_keys", "delete")

        @api_key.destroy!
        render json: { message: "API key permanently deleted" }
      end

      # POST /api/v1/api-keys/:id/revoke
      def revoke
        return unless authorize_action!("api_keys", "update")

        if @api_key.revoked?
          render json: { error: "API key is already revoked" }, status: :unprocessable_entity
          return
        end

        @api_key.revoke!
        render json: {
          api_key: api_key_json(@api_key, detailed: true),
          message: "API key revoked successfully"
        }
      end

      private

      def set_api_key
        @api_key = @company.api_keys.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "API key not found" }, status: :not_found
      end

      def api_key_params
        params.permit(:name, :rate_limit, permissions: {})
      end

      def api_key_update_params
        params.permit(:name, :status, :rate_limit, permissions: {})
      end

      def api_key_json(api_key, detailed: false)
        json = {
          id: api_key.id,
          name: api_key.name,
          key_preview: mask_key(api_key.key),
          status: api_key.status,
          created_at: api_key.created_at&.iso8601,
          updated_at: api_key.updated_at&.iso8601
        }

        if detailed
          json.merge!(
            permissions: api_key.permissions,
            rate_limit: api_key.rate_limit,
            request_count: api_key.request_count,
            last_used_at: api_key.last_used_at&.iso8601,
            created_by_user_id: api_key.created_by_user_id
          )
        end

        json
      end

      def mask_key(key)
        return nil unless key
        "#{key[0..11]}...#{key[-4..]}"
      end
    end
  end
end
