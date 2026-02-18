# frozen_string_literal: true

module Api
  module Partner
    module V1
      class ServiceTicketsController < BaseController
        include PartnerWebhooks
        fires_webhooks resource: :service_ticket

        before_action :authorize_service_tickets
        before_action :set_service_ticket, only: [:show, :update, :destroy]

        # GET /api/partner/v1/service-tickets
        def index
          tickets = company_scope(ServiceTicket).where(deleted_at: nil)

          # Filters
          tickets = tickets.where(status: params[:status]) if params[:status].present?
          tickets = tickets.where(priority: params[:priority]) if params[:priority].present?
          tickets = tickets.where(assigned_to: params[:assigned_to]) if params[:assigned_to].present?
          tickets = tickets.where(vehicle_id: params[:vehicle_id]) if params[:vehicle_id].present?
          tickets = tickets.where(contact_id: params[:contact_id]) if params[:contact_id].present?
          tickets = tickets.where(account_id: params[:account_id]) if params[:account_id].present?
          tickets = tickets.where(location_id: params[:location_id]) if params[:location_id].present?
          tickets = tickets.where(deal_id: params[:deal_id]) if params[:deal_id].present?
          tickets = tickets.where(is_warranty_suspected: true) if params[:warranty_suspected] == "true"

          # Search
          if params[:q].present?
            q = "%#{params[:q]}%"
            tickets = tickets.where(
              "title ILIKE :q OR ticket_number ILIKE :q OR description ILIKE :q",
              q: q
            )
          end

          # Cursor-based pagination
          tickets = tickets.order(:id)
          tickets = tickets.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          tickets = tickets.limit(limit + 1)

          records = tickets.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |t| service_ticket_json(t) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/service-tickets/:id
        def show
          render json: { data: service_ticket_json(@service_ticket, detailed: true) }
        end

        # POST /api/partner/v1/service-tickets
        def create
          ticket = company_scope(ServiceTicket).new(service_ticket_params)

          if ticket.save
            render json: { data: service_ticket_json(ticket, detailed: true) }, status: :created
          else
            render json: { error: "Validation failed", details: ticket.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/partner/v1/service-tickets/:id
        def update
          if @service_ticket.update(service_ticket_params)
            render json: { data: service_ticket_json(@service_ticket, detailed: true) }
          else
            render json: { error: "Validation failed", details: @service_ticket.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/partner/v1/service-tickets/:id
        def destroy
          @service_ticket.update!(deleted_at: Time.current)
          render json: { data: { id: @service_ticket.id, deleted: true } }
        end

        private

        def authorize_service_tickets
          case action_name
          when "index", "show"
            authorize_permission!(:service_tickets, :read)
          when "create"
            authorize_permission!(:service_tickets, :create)
          when "update"
            authorize_permission!(:service_tickets, :update)
          when "destroy"
            authorize_permission!(:service_tickets, :delete)
          end
        end

        def set_service_ticket
          @service_ticket = company_scope(ServiceTicket).where(deleted_at: nil).find(params[:id])
        end

        def service_ticket_params
          params.permit(
            :title, :description, :status, :priority,
            :assigned_to, :scheduled_date, :completed_date,
            :account_id, :contact_id, :vehicle_id, :deal_id, :location_id,
            :notes, :is_warranty_suspected,
            custom_fields: {},
            parts: [:name, :part_number, :quantity, :unit_cost, :total],
            labor: [:description, :hours, :rate, :total]
          )
        end

        def service_ticket_json(ticket, detailed: false)
          json = {
            id: ticket.id,
            ticket_number: ticket.ticket_number,
            title: ticket.title,
            status: ticket.status,
            priority: ticket.priority,
            assigned_to: ticket.assigned_to,
            scheduled_date: ticket.scheduled_date&.iso8601,
            completed_date: ticket.completed_date&.iso8601,
            account_id: ticket.account_id,
            contact_id: ticket.contact_id,
            vehicle_id: ticket.vehicle_id,
            location_id: ticket.location_id,
            is_warranty_suspected: ticket.is_warranty_suspected,
            created_at: ticket.created_at&.iso8601,
            updated_at: ticket.updated_at&.iso8601
          }

          if detailed
            json.merge!(
              description: ticket.description,
              notes: ticket.notes,
              deal_id: ticket.deal_id,
              warranty_claim_id: ticket.warranty_claim_id,
              is_warranty_confirmed: ticket.is_warranty_confirmed,
              parts: ticket.parts,
              labor: ticket.labor,
              custom_fields: ticket.custom_fields,
              line_item_billing: ticket.line_item_billing,
              parts_total: ticket.parts_total,
              labor_total: ticket.labor_total,
              total_cost: ticket.total_cost
            )
          end

          json
        end
      end
    end
  end
end
