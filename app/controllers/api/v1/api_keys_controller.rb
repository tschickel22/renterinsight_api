# frozen_string_literal: true

module Api
  module V1
    class ApiKeysController < ApplicationController
      before_action :set_company_scope
      before_action :set_api_key, only: [:show, :update, :destroy, :revoke]

      # GET /api/v1/api-keys/available_resources
      def available_resources
        render json: ApiKey.available_resources
      end
      
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

        if (err = webhook_config_error(api_key))
          return render json: { errors: [err] }, status: :unprocessable_entity
        end

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

        # Apply changes in-memory so we can validate webhook_config against the
        # merged final state before writing.
        @api_key.assign_attributes(api_key_update_params)
        if (err = webhook_config_error(@api_key))
          return render json: { errors: [err] }, status: :unprocessable_entity
        end

        if @api_key.save
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

      # POST /api/v1/api-keys/bulk
      #
      # Fan-out create: takes one config + a location_ids array and creates
      # one api_key per location, each with default_location_ids = [that id]
      # baked into its webhook_config. Everything else (permissions, source,
      # assignment, dedupe) is copied verbatim so the caller doesn't need to
      # repeat it N times. Runs in a transaction so a validation error on
      # location #3 rolls back locations #1 and #2 — no orphan keys on the
      # DB even if the caller has to retry.
      #
      # Response mirrors #create for a single key but as an array; each entry
      # includes the raw Bearer token exactly once. The caller MUST surface
      # every token immediately — they're masked after this response.
      def bulk
        return unless authorize_action!("api_keys", "create")

        location_ids = Array(params[:location_ids]).map(&:to_i).reject(&:zero?).uniq
        if location_ids.empty?
          return render json: { errors: ['location_ids is required and must contain at least one location'] },
                        status: :unprocessable_entity
        end

        target_company_id = resolve_target_company_id
        if target_company_id.nil?
          return render json: { errors: ['bulk create requires a company scope (not platform-level)'] },
                        status: :unprocessable_entity
        end

        base_name = params[:name].to_s.strip.presence || 'Inbound Leads'
        # Fetch location names up front so we can suffix each key nicely.
        location_map = Location.where(id: location_ids, company_id: target_company_id).pluck(:id, :name).to_h
        missing = location_ids - location_map.keys
        if missing.any?
          return render json: { errors: ["locations #{missing.inspect} do not belong to company #{target_company_id}"] },
                        status: :unprocessable_entity
        end

        created = []
        ActiveRecord::Base.transaction do
          location_ids.each do |loc_id|
            per_key_config = normalize_webhook_config(params[:webhook_config] || {})
            per_key_config['default_location_ids'] = [loc_id]
            per_key_config['default_location_id']  = loc_id
            per_key_config.delete('round_robin_cursor') # start fresh per key

            # When the caller picked "one user per location" for a bulk create,
            # collapse the map into a scalar assigned_user_id on THIS location's
            # key — every key becomes a plain 'specific' key with the right
            # user, and the map itself is dropped from storage. Keeps each
            # generated key simple + self-contained.
            per_loc_map = per_key_config.delete('assigned_user_ids_by_location') || {}
            if per_key_config['assignment_mode'].to_s == 'specific_per_location'
              scalar_user_id = per_loc_map[loc_id.to_s] || per_loc_map[loc_id]
              per_key_config['assignment_mode'] = 'specific'
              per_key_config['assigned_user_id'] = scalar_user_id.to_i if scalar_user_id
            end

            key = ApiKey.new(
              name: "#{base_name} — #{location_map[loc_id]}",
              rate_limit: (params[:rate_limit] || 1000).to_i,
              permissions: normalize_permissions(params[:permissions] || {}),
              webhook_config: per_key_config,
              company_id: target_company_id,
              created_by_user_id: current_user.id
            )

            if (err = webhook_config_error(key))
              raise ActiveRecord::Rollback.new.tap { @bulk_error = err }
            end

            unless key.save
              @bulk_error = key.errors.full_messages.join(', ')
              raise ActiveRecord::Rollback
            end

            created << key
          end
        end

        if @bulk_error
          return render json: { errors: [@bulk_error] }, status: :unprocessable_entity
        end

        render json: {
          api_keys: created.map do |k|
            json = api_key_json(k, detailed: true)
            json[:key] = k.key
            json[:location_id] = k.webhook_config['default_location_ids']&.first
            json[:location_name] = location_map[json[:location_id]]
            json
          end,
          message: "Generated #{created.size} API #{created.size == 1 ? 'key' : 'keys'}. Save each key now — they will be masked after this response."
        }, status: :created
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

      # Scope API keys based on the ACTIVE company scope, not the caller's role.
      #
      # SECURITY: platform_admin used to fall through to `ApiKey.all` here,
      # which leaked keys across tenants — a platform admin viewing Company
      # A's settings would see Company B's keys. `@company` is always set by
      # `set_company_scope` (either the admin's own company or whatever they
      # switched to via the company selector), so the correct default is to
      # scope to that.
      #
      # Platform admins can still cross-scope explicitly via the URL:
      #   ?company_id=<id>       — a specific different company
      #   ?company_id=platform   — platform-level (company_id NULL) keys
      #   ?company_id=all        — every key across every company
      def scoped_api_keys
        if current_user.role == "platform_admin" && params[:company_id].present?
          case params[:company_id].to_s
          when "platform"
            ApiKey.platform_level
          when "all"
            ApiKey.all
          else
            ApiKey.where(company_id: params[:company_id].to_i)
          end
        else
          # Everyone else — including platform admins with no explicit override
          # — is scoped to the currently active company.
          @company ? @company.api_keys : ApiKey.none
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
        if params[:webhook_config].present?
          permitted[:webhook_config] = normalize_webhook_config(params[:webhook_config])
        end
        permitted
      end

      def api_key_update_params
        permitted = params.permit(:name, :status, :rate_limit)
        if params[:permissions].present?
          permitted[:permissions] = normalize_permissions(params[:permissions])
        end
        if params[:webhook_config].present?
          permitted[:webhook_config] = normalize_webhook_config(params[:webhook_config])
        end
        permitted
      end

      # A key that can create leads MUST have a default_location_id — otherwise
      # inbound Zapier/FB leads land with location_id nil and get hidden from
      # every location-scoped RBAC user (per for_current_location). Silent
      # orphaning is worse than blocking the key create.
      #
      # Also validates that any user IDs referenced actually belong to the
      # target company — prevents cross-tenant assignment.
      def webhook_config_error(api_key)
        cfg = (api_key.webhook_config || {}).with_indifferent_access
        return nil if cfg.blank?

        can_create_leads = api_key.permissions.is_a?(Hash) &&
                           Array(api_key.permissions['leads']).map(&:to_s).include?('write')
        return nil unless can_create_leads

        location_ids = Array(cfg['default_location_ids']).compact.map(&:to_i).reject(&:zero?)
        location_ids = [cfg['default_location_id'].to_i] if location_ids.empty? && cfg['default_location_id'].present?

        if location_ids.empty?
          return 'webhook_config.default_location_ids (or default_location_id) is required for keys that can create leads (prevents orphaned inbound leads)'
        end

        company_id = api_key.company_id
        return nil unless company_id

        # Sanity-check every location belongs to this company.
        valid_ids = Location.where(id: location_ids, company_id: company_id).pluck(:id)
        invalid = location_ids - valid_ids
        if invalid.any?
          return "webhook_config default_location_ids #{invalid.inspect} do not belong to company #{company_id}"
        end

        # Check any assigned users belong to this company (scalar + list + per-location map)
        per_loc_map = (cfg['assigned_user_ids_by_location'] || {})
        per_loc_user_ids = per_loc_map.values.map(&:to_i)
        candidate_ids = [cfg['assigned_user_id']].compact + Array(cfg['assigned_user_ids']) + per_loc_user_ids
        candidate_ids = candidate_ids.map(&:to_i).reject(&:zero?).uniq
        if candidate_ids.any?
          valid = User.where(id: candidate_ids, company_id: company_id).pluck(:id)
          invalid = candidate_ids - valid
          if invalid.any?
            return "webhook_config assigned users not in company #{company_id}: #{invalid.join(', ')}"
          end
        end

        # If the caller chose per-location assignment, EVERY selected location
        # must have a user picked. Otherwise a lead for the missing location
        # falls through to "unassigned" silently — the exact orphaning problem
        # this feature is trying to prevent for source/location.
        if cfg['assignment_mode'].to_s == 'specific_per_location'
          missing_for = location_ids - per_loc_map.keys.map(&:to_i)
          if missing_for.any?
            return "webhook_config assignment_mode=specific_per_location requires a user for every location; missing users for locations #{missing_for.inspect}"
          end
        end

        nil
      end

      # Whitelist just the keys the backend actually reads on the inbound-lead
      # path. Anything else the client sends is ignored — no ad-hoc keys leak
      # into the JSONB column.
      def normalize_webhook_config(raw)
        h = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
        return {} unless h.is_a?(Hash)
        allowed = %w[
          default_source_id default_source_name
          default_location_id default_location_ids
          assignment_mode assigned_user_id assigned_user_ids assigned_user_ids_by_location
          round_robin_list_id round_robin_cursor
          dedupe_enabled
        ]
        result = {}
        h.each do |k, v|
          key = k.to_s
          next unless allowed.include?(key)
          # Coerce booleans, arrays, strings, and integers so the JSONB stays typed sanely.
          result[key] = case key
                       when 'dedupe_enabled' then ActiveModel::Type::Boolean.new.cast(v)
                       when 'assignment_mode' then v.to_s
                       when 'default_source_name' then v.to_s.presence
                       when 'assigned_user_ids', 'default_location_ids' then Array(v).map(&:to_i).reject(&:zero?)
                       when 'assigned_user_ids_by_location'
                         # { "48" => 12, "49" => 15 } — normalize both sides to
                         # strings-of-integers keys and integer values so the
                         # JSONB read path doesn't need to guess types.
                         raw_map = v.respond_to?(:to_unsafe_h) ? v.to_unsafe_h : v
                         raw_map.is_a?(Hash) ? raw_map.each_with_object({}) { |(lk, lv), acc|
                           loc_id = lk.to_i
                           usr_id = lv.to_i
                           acc[loc_id.to_s] = usr_id if loc_id.positive? && usr_id.positive?
                         } : {}
                       else v.presence && v.to_i
                       end
        end
        # Normalize: if the caller passed the scalar `default_location_id` OR
        # the array `default_location_ids`, always store the array form so the
        # runtime code has one shape to read. The scalar is still permitted on
        # the wire for backward compat and single-location keys.
        if result['default_location_id'].present? && result['default_location_ids'].blank?
          result['default_location_ids'] = [result['default_location_id'].to_i]
        end
        result['default_location_id'] = result['default_location_ids']&.first if result['default_location_ids'].present?
        # If a source NAME was provided, resolve it to an id up front so
        # runtime lookup stays fast (SourceResolverService still runs on the
        # webhook path, but this avoids a fuzzy match on every request when
        # the operator already picked one at key-creation time).
        if result['default_source_name'].present? && result['default_source_id'].blank? && @company
          resolved = SourceResolverService.resolve(company: @company, source_name: result['default_source_name'])
          result['default_source_id'] = resolved&.id
        end
        result.delete('default_source_name')
        result
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
