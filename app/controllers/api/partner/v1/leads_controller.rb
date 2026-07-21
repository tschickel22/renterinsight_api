# frozen_string_literal: true

module Api
  module Partner
    module V1
      class LeadsController < BaseController
        include PartnerWebhooks
        fires_webhooks resource: :lead

        before_action :authorize_leads
        before_action :set_lead, only: [:show, :update, :destroy]

        # GET /api/partner/v1/leads
        def index
          leads = company_scope(Lead)

          # Filters
          leads = leads.where(status: params[:status]) if params[:status].present?
          leads = leads.where(source_id: params[:source_id]) if params[:source_id].present?
          leads = leads.where(owner_id: params[:owner_id]) if params[:owner_id].present?
          leads = leads.where(location_id: params[:location_id]) if params[:location_id].present?
          leads = leads.where(is_converted: params[:is_converted]) if params[:is_converted].present?

          # Search
          if params[:q].present?
            q = "%#{params[:q]}%"
            leads = leads.where(
              "first_name ILIKE :q OR last_name ILIKE :q OR email ILIKE :q OR CONCAT(first_name, ' ', last_name) ILIKE :q",
              q: q
            )
          end

          # Cursor-based pagination
          leads = leads.order(:id)
          leads = leads.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          leads = leads.limit(limit + 1)

          records = leads.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |l| lead_json(l) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/leads/:id
        def show
          render json: { data: lead_json(@lead, detailed: true) }
        end

        # POST /api/partner/v1/leads
        #
        # Applies the current API key's webhook_config in this order before
        # saving so a Zapier/FB payload becomes a well-attributed, well-assigned
        # lead even when the caller can't map every field:
        #
        #   1. Source — SourceResolverService takes payload source_id/source
        #      and falls back to webhook_config.default_source_id, with fuzzy
        #      matching + auto-creation for unknown names.
        #   2. Location — payload wins; otherwise webhook_config.default_location_id.
        #   3. Owner — payload wins; otherwise webhook_config.assignment_mode
        #      picks (specific user, round-robin from a shared list, or leave
        #      unassigned for a workflow to handle).
        #   4. Dedupe — if webhook_config.dedupe_enabled and IdentityResolver
        #      matches an existing Lead or Contact by email/phone, we DON'T
        #      create a duplicate. We return 202 with the matched record so
        #      Zapier's history reflects "handled, not duplicated."
        def create
          attrs = lead_params.to_h.symbolize_keys
          config = webhook_config

          apply_source_config!(attrs, config)
          apply_location_config!(attrs, config)

          if config['dedupe_enabled'] && (match = dedupe_match(attrs))
            return render json: {
              data: nil,
              deduped_to: { type: match.type.to_s, id: match.record.id, matched_on: match.matched.to_s }
            }, status: :accepted
          end

          apply_owner_config!(attrs, config)

          lead = company_scope(Lead).new(attrs)

          if lead.save
            render json: { data: lead_json(lead, detailed: true) }, status: :created
          else
            render json: { error: "Validation failed", details: lead.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/partner/v1/leads/:id
        def update
          if @lead.update(lead_params)
            render json: { data: lead_json(@lead, detailed: true) }
          else
            render json: { error: "Validation failed", details: @lead.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/partner/v1/leads/:id
        def destroy
          @lead.destroy!
          render json: { data: { id: @lead.id, deleted: true } }
        end

        private

        def authorize_leads
          case action_name
          when "index", "show"
            authorize_permission!(:leads, :read)
          when "create"
            authorize_permission!(:leads, :create)
          when "update"
            authorize_permission!(:leads, :update)
          when "destroy"
            authorize_permission!(:leads, :delete)
          end
        end

        def set_lead
          @lead = company_scope(Lead).find(params[:id])
        end

        def lead_params
          params.permit(
            :first_name, :last_name, :email, :phone, :status,
            :source_id, :source, :owner_id, :location_id,
            :budget_range, :purchase_timeframe, :rv_experience,
            :preferred_contact_method, :interests_requirements, :notes
          )
        end

        def webhook_config
          (current_api_key&.webhook_config || {}).with_indifferent_access
        end

        def apply_source_config!(attrs, config)
          resolved = SourceResolverService.resolve(
            company: @current_company,
            source_id: attrs[:source_id],
            source_name: attrs.delete(:source),
            default_source_id: config['default_source_id']
          )
          attrs[:source_id] = resolved&.id if resolved && attrs[:source_id].blank?
        end

        def apply_location_config!(attrs, config)
          return if attrs[:location_id].present?
          attrs[:location_id] = config['default_location_id'] if config['default_location_id'].present?
        end

        def apply_owner_config!(attrs, config)
          return if attrs[:owner_id].present?

          case config['assignment_mode'].to_s
          when 'specific'
            user_id = config['assigned_user_id']
            attrs[:owner_id] = user_id if user_id.present? && User.exists?(id: user_id, company_id: @current_company.id, status: 'active')
          when 'round_robin'
            list_id = config['round_robin_list_id']
            list = RoundRobinAssignmentList.active.find_by(id: list_id, company_id: @current_company.id)
            picked = list&.next_active_user!
            attrs[:owner_id] = picked.id if picked
          # 'unassigned' or unknown: leave nil, downstream workflow handles it
          end
        end

        def dedupe_match(attrs)
          return nil if attrs[:email].blank? && attrs[:phone].blank?
          IdentityResolver.new(@current_company, email: attrs[:email], phone: attrs[:phone]).resolve
        end

        def lead_json(lead, detailed: false)
          json = {
            id: lead.id,
            first_name: lead.first_name,
            last_name: lead.last_name,
            email: lead.email,
            phone: lead.phone,
            status: lead.status,
            source_id: lead.source_id,
            owner_id: lead.owner_id,
            location_id: lead.location_id,
            is_converted: lead.is_converted,
            created_at: lead.created_at&.iso8601,
            updated_at: lead.updated_at&.iso8601
          }

          if detailed
            json.merge!(
              converted_at: lead.converted_at&.iso8601,
              converted_account_id: lead.converted_account_id,
              budget_range: lead.budget_range,
              purchase_timeframe: lead.purchase_timeframe,
              rv_experience: lead.rv_experience,
              preferred_contact_method: lead.preferred_contact_method,
              interests_requirements: lead.interests_requirements,
              notes: lead.notes
            )
          end

          json
        end
      end
    end
  end
end
