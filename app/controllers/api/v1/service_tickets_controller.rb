# frozen_string_literal: true

module Api
  module V1
    class ServiceTicketsController < ApplicationController
      before_action :set_company
      before_action :set_service_ticket, only: [:show, :update, :destroy]
      
      # GET /api/v1/service-tickets
      def index
        return unless authorize_action!('service', 'read')
        
        # STRICT TENANT ISOLATION: Only return service tickets from current user's company
        # RBAC: Location-tier users only see their assigned locations (STRICT - no NULL fallback)
        @service_tickets = if current_user.uses_rbac?
          if current_user.effective_admin?  # Use RBAC-aware admin check
            @company.service_tickets
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              # STRICT: Only tickets in assigned locations (no NULL fallback)
              @company.service_tickets.where(location_id: location_ids)
            else
              @company.service_tickets
            end
          end
        else
          @company.service_tickets
        end
        
        # Apply location selector filter (if user selected a specific location)
        if Current.location_filtered?
          @service_tickets = @service_tickets.where(location_id: Current.location_id)
        end
        
        @service_tickets = @service_tickets.includes(:account, :contact, :vehicle).recent
        
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
        return unless authorize_action!('service', 'read')
        
        render json: {
          data: serialize_ticket(@service_ticket)
        }
      end
      
      # POST /api/v1/service-tickets
      def create
        return unless authorize_action!('service', 'create')
        
        @service_ticket = @company.service_tickets.new(service_ticket_params)
        
        # Auto-assign location from selector (if user selected a specific location)
        @service_ticket.location_id ||= Current.location_id if Current.location_id.present?
        
        # RBAC fallback: Location-tier users auto-assign to their first location if no selector
        if @service_ticket.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          @service_ticket.location_id ||= location_ids.first if location_ids.any?
        end
        
        if @service_ticket.save
          render json: { data: serialize_ticket(@service_ticket) }, status: :created
        else
          render json: { errors: @service_ticket.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH/PUT /api/v1/service-tickets/:id
      def update
        return unless authorize_action!('service', 'update')
        
        if @service_ticket.update(service_ticket_params)
          render json: { data: serialize_ticket(@service_ticket) }
        else
          render json: { errors: @service_ticket.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/service-tickets/:id
      def destroy
        return unless authorize_action!('service', 'delete')
        
        @service_ticket.destroy
        head :no_content
      end
      
      # GET /api/v1/service-tickets/stats
      def stats
        return unless authorize_action!('service', 'read')
        
        tickets = @company.service_tickets
        
        # Apply location selector filter for stats (if user selected a specific location)
        if Current.location_filtered?
          tickets = tickets.where(location_id: Current.location_id)
        end
        
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
        # STRICT TENANT ISOLATION: Only find service tickets within company
        # RBAC: Location-tier users only access their assigned locations (STRICT - no NULL fallback)
        @service_ticket = if current_user.uses_rbac? && !current_user.effective_admin?  # Use RBAC-aware admin check
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            # STRICT: Only tickets in assigned locations (no NULL fallback)
            @company.service_tickets.where(location_id: location_ids).find(params[:id])
          else
            @company.service_tickets.find(params[:id])
          end
        else
          @company.service_tickets.find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Service ticket not found or access denied' }, status: :not_found
        return
      end
      
      def set_company
        # STRICT TENANT ISOLATION: Only load company from authenticated user
        unless current_user
          Rails.logger.error "🚫 [ServiceTicketsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [ServiceTicketsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [ServiceTicketsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [ServiceTicketsController] Company scope set: #{@company.name} (ID: #{@company.id})"
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
        # Ensure parts and labor are always arrays
        parts_array = ticket.parts.is_a?(Array) ? ticket.parts : (ticket.parts.present? ? (JSON.parse(ticket.parts) rescue []) : [])
        labor_array = ticket.labor.is_a?(Array) ? ticket.labor : (ticket.labor.present? ? (JSON.parse(ticket.labor) rescue []) : [])
        custom_fields_hash = ticket.custom_fields.is_a?(Hash) ? ticket.custom_fields : (ticket.custom_fields.present? ? (JSON.parse(ticket.custom_fields) rescue {}) : {})
        
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
          parts: parts_array,
          labor: labor_array,
          customFields: custom_fields_hash,
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
