# frozen_string_literal: true

module Api
  module V1
    class ApiKeysController < ApplicationController
      before_action :set_company_scope
      before_action :set_api_key, only: [:show, :update, :destroy, :revoke]

      # GET /api/v1/api-keys
      def index
        return unless authorize_action!("api_keys", "read")

        api_keys = scoped_api_keys.order(created_at: :desc)

        render json: {
          api_keys: api_keys.map { |k| api_key_json(k, detailed: true) },
          meta: {
            total: api_keys.count,
            company_id: @company&.id
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

        # Platform admins can create platform-level or company-scoped keys
        target_company_id = resolve_target_company_id
        
        api_key = ApiKey.new(api_key_params)
        api_key.company_id = target_company_id
        api_key.created_by_user_id = current_user.id

        if api_key.save
          # Return the full key ONCE — it cannot be retrieved again (only a masked preview is stored)
          json = api_key_json(api_key, detailed: true)
          json[:key] = api_key.key

          render json: {
            api_key: json,
            message: "API key created. Save the key now — only a masked preview will be shown after this."
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

      # Scope API keys based on user role:
      # - Platform admin: sees all (platform-level + all companies)
      # - Company admin: sees only their company's keys
      def scoped_api_keys
        if current_user.role == "platform_admin"
          # Platform admins see everything
          # Optionally filter by company_id param
          if params[:company_id].present?
            if params[:company_id] == "platform"
              ApiKey.platform_level
            else
              ApiKey.where(company_id: params[:company_id])
            end
          else
            ApiKey.all
          end
        else
          @company.api_keys
        end
      end

      def set_api_key
        @api_key = scoped_api_keys.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "API key not found" }, status: :not_found
      end

      # Resolve which company_id to assign to a new key
      # - Platform admin can pass company_id param or "platform" for no company
      # - Company admin always gets their company
      def resolve_target_company_id
        if current_user.role == "platform_admin"
          if params[:company_id].blank? || params[:company_id].to_s == "platform"
            nil  # Platform-level key
          else
            params[:company_id].to_i
          end
        else
          @company.id
        end
      end

      def api_key_params
        permitted = params.permit(:name, :rate_limit)
        if params[:permissions].present?
          permitted[:permissions] = normalize_permissions(params[:permissions])
        end
        permitted
      end

      def api_key_update_params
        permitted = params.permit(:name, :status, :rate_limit)
        if params[:permissions].present?
          permitted[:permissions] = normalize_permissions(params[:permissions])
        end
        permitted
      end

      # Accept either hash format { "contacts" => ["read", "write"] }
      # or array format [{ "resource" => "contacts", "read" => true, "write" => true }]
      def normalize_permissions(raw_perms)
        return {} if raw_perms.blank?

        if raw_perms.is_a?(Array) || (raw_perms.is_a?(ActionController::Parameters) && raw_perms.to_unsafe_h.keys.all? { |k| k.to_s =~ /\A\d+\z/ })
          result = {}
          Array(raw_perms).each do |perm|
            perm = perm.to_unsafe_h if perm.respond_to?(:to_unsafe_h)
            resource = perm["resource"]&.downcase
            next unless resource
            actions = []
            actions << "read" if perm["read"].to_s == "true"
            actions << "write" if perm["write"].to_s == "true"
            result[resource] = actions if actions.any?
          end
          result
        else
          raw_perms.to_unsafe_h.transform_keys(&:to_s)
        end
      end

      def api_key_json(api_key, detailed: false)
        json = {
          id: api_key.id,
          name: api_key.name,
          key_preview: mask_key(api_key.key),
          status: api_key.status,
          company_id: api_key.company_id,
          company_name: api_key.company&.name,
          scope: api_key.platform_level? ? "platform" : "company",
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
