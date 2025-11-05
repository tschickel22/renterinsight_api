# frozen_string_literal: true

module Api
  module V1
    class ServiceTicketsController < ApplicationController
      before_action :set_company
      before_action :set_service_ticket, only: [:show, :update, :destroy]

      def index
        service_tickets = @company.service_tickets.where(deleted_at: nil)
        
        # Filters
        service_tickets = service_tickets.where(status: params[:status]) if params[:status].present?
        service_tickets = service_tickets.where(priority: params[:priority]) if params[:priority].present?
        service_tickets = service_tickets.where(assigned_to: params[:assigned_to]) if params[:assigned_to].present?
        
        # Search
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          service_tickets = service_tickets.where(
            "title LIKE ? OR description LIKE ?", 
            search_term, search_term
          )
        end

        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order] || 'desc'
        service_tickets = service_tickets.order("#{sort_by} #{sort_order}")

        # Pagination
        page = params[:page]&.to_i || 1
        per_page = [params[:per_page]&.to_i || 25, 100].min
        total_count = service_tickets.count
        service_tickets = service_tickets.offset((page - 1) * per_page).limit(per_page)

        render json: {
          data: service_tickets.map { |st| service_ticket_json(st) },
          meta: {
            current_page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      def show
        render json: { data: service_ticket_json(@service_ticket, detailed: true) }
      end

      def create
        service_ticket = @company.service_tickets.new(service_ticket_params)

        if service_ticket.save
          render json: { data: service_ticket_json(service_ticket, detailed: true) }, status: :created
        else
          render json: { errors: service_ticket.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        if @service_ticket.update(service_ticket_params)
          render json: { data: service_ticket_json(@service_ticket, detailed: true) }
        else
          render json: { errors: @service_ticket.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @service_ticket.update!(deleted_at: Time.current)
        head :no_content
      end

      def stats
        service_tickets = @company.service_tickets.where(deleted_at: nil)
        
        render json: {
          data: {
          total: service_tickets.count,
          by_status: service_tickets.group(:status).count,
          by_priority: service_tickets.group(:priority).count,
          open: service_tickets.where(status: 'open').count,
          in_progress: service_tickets.where(status: 'in_progress').count,
          completed: service_tickets.where(status: 'completed').count,
          scheduled_this_week: service_tickets.where(
            'scheduled_date >= ? AND scheduled_date <= ?',
            Time.current.beginning_of_week,
            Time.current.end_of_week
          ).count
          }
        }
      end

      def export
        service_tickets = @company.service_tickets.where(deleted_at: nil)
        
        # Apply same filters as index
        service_tickets = service_tickets.where(status: params[:status]) if params[:status].present?
        service_tickets = service_tickets.where(priority: params[:priority]) if params[:priority].present?
        
        # Generate CSV
        require 'csv'
        csv_data = CSV.generate(headers: true) do |csv|
          # Headers
          csv << [
            'ID',
            'Title',
            'Status',
            'Priority',
            'Assigned To',
            'Account',
            'Contact',
            'Vehicle',
            'Scheduled Date',
            'Completed Date',
            'Created At'
          ]
          
          # Data rows
          service_tickets.each do |ticket|
            csv << [
              ticket.id,
              ticket.title,
              ticket.status,
              ticket.priority,
              ticket.assigned_to,
              ticket.account&.name,
              ticket.contact&.first_name,
              ticket.vehicle_id,
              ticket.scheduled_date&.strftime('%Y-%m-%d'),
              ticket.completed_date&.strftime('%Y-%m-%d'),
              ticket.created_at&.strftime('%Y-%m-%d')
            ]
          end
        end
        
        # Send CSV file
        send_data csv_data,
          filename: "service-tickets-export-#{Date.today}.csv",
          type: 'text/csv',
          disposition: 'attachment'
      end

      private

      def set_company
        # Try to find company from current_user if available
        if current_user.respond_to?(:company_id) && current_user.company_id
          @company = ::Company.find_by(id: current_user.company_id)
        end
        
        # Fallback to first company if none found (for demo/dev)
        @company ||= ::Company.first
        
        unless @company
          render json: { error: 'Company not found' }, status: :not_found
        end
      end

      def set_service_ticket
        @service_ticket = @company.service_tickets.where(deleted_at: nil).find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Service ticket not found' }, status: :not_found
      end

      def service_ticket_params
        params.require(:service_ticket).permit(
          :title,
          :description,
          :priority,
          :status,
          :assigned_to,
          :account_id,
          :contact_id,
          :customer_id,
          :vehicle_id,
          :scheduled_date,
          :completed_date,
          :notes,
          parts: [:id, :partNumber, :part_number, :name, :description, :quantity, :unitCost, :unit_cost, :cost, :total],
          labor: [:id, :description, :hours, :rate, :total],
          custom_fields: {}
        )
      end

      def service_ticket_json(ticket, detailed: false)
        json = {
          id: ticket.id.to_s,
          title: ticket.title,
          description: ticket.description,
          priority: ticket.priority,
          status: ticket.status,
          assignedTo: ticket.assigned_to,
          accountId: ticket.account_id&.to_s,
          contactId: ticket.contact_id&.to_s,
          customerId: ticket.customer_id&.to_s,
          vehicleId: ticket.vehicle_id&.to_s,
          scheduledDate: ticket.scheduled_date,
          completedDate: ticket.completed_date,
          parts: ticket.parts || [],
          labor: ticket.labor || [],
          notes: ticket.notes,
          customFields: ticket.custom_fields || {},
          createdAt: ticket.created_at,
          updatedAt: ticket.updated_at
        }

        if detailed
          json[:account] = ticket.account ? account_summary(ticket.account) : nil
          json[:contact] = ticket.contact ? contact_summary(ticket.contact) : nil
        end

        json
      end

      def account_summary(account)
        {
          id: account.id.to_s,
          name: account.name,
          email: account.email,
          phone: account.phone
        }
      end

      def contact_summary(contact)
        {
          id: contact.id.to_s,
          firstName: contact.first_name,
          lastName: contact.last_name,
          email: contact.email,
          phone: contact.phone
        }
      end
    end
  end
end
