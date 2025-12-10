# frozen_string_literal: true

module Api
  module Portal
    class ServiceTicketsController < ApplicationController
      skip_before_action :authenticate
      before_action :authenticate_portal_user!
      
      # GET /api/portal/service-tickets
      def index
        tickets = ServiceTicket
          .where(company_id: current_portal_user.company_id)
          .where("account_id = ? OR contact_id = ?", 
                 current_portal_user.buyer_id, 
                 current_portal_user.buyer_id)
          .order(created_at: :desc)
        
        render json: {
          success: true,
          tickets: tickets.map { |ticket| serialize_ticket(ticket) }
        }
      end
      
      # GET /api/portal/service-tickets/:id
      def show
        ticket = ServiceTicket
          .where(company_id: current_portal_user.company_id)
          .where("account_id = ? OR contact_id = ?", 
                 current_portal_user.buyer_id, 
                 current_portal_user.buyer_id)
          .find(params[:id])
        
        render json: {
          success: true,
          ticket: serialize_ticket(ticket, include_details: true)
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Service ticket not found' }, status: :not_found
      end
      
      # POST /api/portal/service-tickets
      def create
        # Get account from portal user's buyer relationship
        account = current_portal_user.buyer_type == 'Account' ? 
                  current_portal_user.buyer : 
                  current_portal_user.buyer&.account
        
        unless account
          return render json: { error: 'No account associated with portal user' }, 
                       status: :unprocessable_entity
        end
        
        ticket = ServiceTicket.new(ticket_params)
        ticket.company_id = current_portal_user.company_id
        ticket.account_id = account.id
        ticket.contact_id = current_portal_user.buyer_id if current_portal_user.buyer_type == 'Contact'
        ticket.portal_user_id = current_portal_user.id
        ticket.is_portal_created = true
        ticket.status = 'pending_review'
        
        # Set default priority if not provided
        ticket.priority ||= 'medium'
        
        if ticket.save
          # TODO: Send notification to company staff
          # ServiceTicketNotificationJob.perform_later(ticket.id, 'created')
          
          render json: {
            success: true,
            ticket: serialize_ticket(ticket),
            message: 'Service request submitted successfully. We will review and contact you shortly.'
          }, status: :created
        else
          render json: {
            success: false,
            errors: ticket.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      private
      
      def authenticate_portal_user!
        token = request.headers['Authorization']&.split(' ')&.last
        
        unless token
          return render json: { error: 'Authorization token required' }, 
                       status: :unauthorized
        end
        
        begin
          decoded = JsonWebToken.decode(token)
          @current_portal_user = BuyerPortalAccess.find(decoded[:buyer_portal_access_id])
          
          unless @current_portal_user.portal_enabled
            return render json: { error: 'Portal access disabled' }, 
                         status: :forbidden
          end
        rescue JWT::DecodeError, ActiveRecord::RecordNotFound
          render json: { error: 'Invalid or expired token' }, 
                 status: :unauthorized
        end
      end
      
      def current_portal_user
        @current_portal_user
      end
      
      def ticket_params
        params.require(:service_ticket).permit(
          :title,
          :description,
          :priority,
          :scheduled_date,
          :portal_notes,
          :vehicle_id
        )
      end
      
      def serialize_ticket(ticket, include_details: false)
        data = {
          id: ticket.id,
          title: ticket.title,
          description: ticket.description,
          status: ticket.status,
          priority: ticket.priority,
          scheduledDate: ticket.scheduled_date,
          portalNotes: ticket.portal_notes,
          createdAt: ticket.created_at,
          updatedAt: ticket.updated_at,
          statusLabel: status_label(ticket.status)
        }
        
        if include_details
          data[:notes] = ticket.notes
          data[:assignedTo] = ticket.assigned_to
          
          # Include parts and labor if present
          parts_array = ticket.parts.is_a?(Array) ? ticket.parts : []
          labor_array = ticket.labor.is_a?(Array) ? ticket.labor : []
          
          data[:parts] = parts_array
          data[:labor] = labor_array
          data[:totalCost] = ticket.total_cost
          
          # Include attachments count
          data[:attachmentsCount] = ticket.attachments.count
        end
        
        data
      end
      
      def status_label(status)
        {
          'pending_review' => 'Pending Review',
          'open' => 'Open',
          'in_progress' => 'In Progress',
          'waiting_on_manufacturer' => 'Waiting on Parts',
          'waiting_parts' => 'Waiting on Parts',
          'completed' => 'Completed',
          'cancelled' => 'Cancelled'
        }[status] || status.titleize
      end
    end
  end
end
