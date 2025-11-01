# frozen_string_literal: true

module Api
  module V1
    class ServiceTicketsController < ApplicationController
      before_action :set_service_ticket, only: [:show, :update, :destroy]
      before_action :set_company
      
      # GET /api/v1/service-tickets
      def index
        @service_tickets = @company.service_tickets
                                    .includes(:account, :contact, :vehicle)
                                    .recent
        
        # Apply filters
        @service_tickets = @service_tickets.where(status: params[:status]) if params[:status].present?
        @service_tickets = @service_tickets.where(priority: params[:priority]) if params[:priority].present?
        @service_tickets = @service_tickets.assigned_to(params[:assigned_to]) if params[:assigned_to].present?
        @service_tickets = @service_tickets.where(account_id: params[:account_id]) if params[:account_id].present?
        
        render json: {
          data: @service_tickets.map { |ticket| serialize_ticket(ticket) }
        }
      end
      
      # GET /api/v1/service-tickets/:id
      def show
        render json: {
          data: serialize_ticket(@service_ticket)
        }
      end
      
      # POST /api/v1/service-tickets
      def create
        @service_ticket = @company.service_tickets.new(service_ticket_params)
        
        if @service_ticket.save
          render json: { data: serialize_ticket(@service_ticket) }, status: :created
        else
          render json: { errors: @service_ticket.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH/PUT /api/v1/service-tickets/:id
      def update
        if @service_ticket.update(service_ticket_params)
          render json: { data: serialize_ticket(@service_ticket) }
        else
          render json: { errors: @service_ticket.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/service-tickets/:id
      def destroy
        @service_ticket.destroy
        head :no_content
      end
      
      # GET /api/v1/service-tickets/stats
      def stats
        tickets = @company.service_tickets
        
        stats_data = {
          total: tickets.count,
          open: tickets.open.count,
          in_progress: tickets.in_progress.count,
          completed: tickets.completed.count,
          overdue: tickets.where('scheduled_date < ? AND status != ?', Date.today, 'completed').count,
          total_revenue: tickets.sum { |t| t.total_cost }
        }
        
        render json: { data: stats_data }
      end
      
      private
      
      def set_service_ticket
        @service_ticket = @company.service_tickets.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Service ticket not found' }, status: :not_found
      end
      
      def set_company
        # TODO: Get company from current_user when auth is implemented
        @company = ::Company.first
      end
      
      def service_ticket_params
        params.require(:service_ticket).permit(
          :account_id,
          :contact_id,
          :vehicle_id,
          :title,
          :description,
          :status,
          :priority,
          :assigned_to,
          :scheduled_date,
          :notes,
          parts: [:id, :part_number, :description, :quantity, :unit_cost, :total],
          labor: [:id, :description, :hours, :rate, :total],
          custom_fields: {}
        )
      end
      
      def serialize_ticket(ticket)
        {
          id: ticket.id,
          accountId: ticket.account_id,
          contactId: ticket.contact_id,
          vehicleId: ticket.vehicle_id,
          title: ticket.title,
          description: ticket.description,
          status: ticket.status,
          priority: ticket.priority,
          assignedTo: ticket.assigned_to,
          scheduledDate: ticket.scheduled_date,
          notes: ticket.notes,
          parts: ticket.parts,
          labor: ticket.labor,
          customFields: ticket.custom_fields,
          createdAt: ticket.created_at,
          updatedAt: ticket.updated_at,
          account: ticket.account ? {
            id: ticket.account.id,
            name: ticket.account.name
          } : nil,
          contact: ticket.contact ? {
            id: ticket.contact.id,
            firstName: ticket.contact.first_name,
            lastName: ticket.contact.last_name
          } : nil,
          vehicle: ticket.vehicle ? {
            id: ticket.vehicle.id,
            year: ticket.vehicle.year,
            make: ticket.vehicle.make,
            model: ticket.vehicle.model
          } : nil
        }
      end
    end
  end
end
