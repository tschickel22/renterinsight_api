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
        def create
          lead = company_scope(Lead).new(lead_params)

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
            :source_id, :owner_id, :location_id,
            :budget_range, :purchase_timeframe, :rv_experience,
            :preferred_contact_method, :interests_requirements, :notes
          )
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
