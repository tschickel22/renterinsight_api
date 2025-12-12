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
          .where(portal_visible: true)  # Only show portal-visible tickets
          .where("account_id = ? OR contact_id = ?", 
                 current_portal_user.buyer_id, 
                 current_portal_user.buyer_id)
          .order(created_at: :desc)
        
        render json: {
          success: true,
          data: tickets.map { |ticket| serialize_ticket(ticket) }
        }
      end
      
      # GET /api/portal/service-tickets/:id
      def show
        ticket = ServiceTicket
          .where(company_id: current_portal_user.company_id)
          .where(portal_visible: true)  # Only show portal-visible tickets
          .where("account_id = ? OR contact_id = ?", 
                 current_portal_user.buyer_id, 
                 current_portal_user.buyer_id)
          .find(params[:id])
        
        render json: {
          success: true,
          data: serialize_ticket(ticket, include_details: true)
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
        ticket.portal_visible = true  # Default: visible to portal
        
        # CRITICAL: Set location_id from account so staff can see it
        ticket.location_id = account.location_id if account.location_id.present?
        
        # Set default priority if not provided
        ticket.priority ||= 'medium'
        
        if ticket.save
          # Handle file attachments if provided
          if params[:files].present?
            params[:files].each do |file|
              ticket.attachments.attach(file)
            end
          end
          
          # TODO: Send notification to company staff
          # ServiceTicketNotificationJob.perform_later(ticket.id, 'created')
          
          render json: {
            success: true,
            data: serialize_ticket(ticket, include_details: true),
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
          :home_info,
          :vehicle_id
        )
      end
      
      # Note: Files are handled separately via params[:files] to support multipart/form-data
      
      def serialize_ticket(ticket, include_details: false)
        # ALWAYS calculate costs (for both list and detail views)
        parts_array = ticket.parts.is_a?(Array) ? ticket.parts : []
        labor_array = ticket.labor.is_a?(Array) ? ticket.labor : []
        
        customer_total = 0
        warranty_total = 0
        
        # Parse line_item_billing safely with error handling
        billing_data = nil
        if ticket.line_item_billing.present?
          begin
            billing_data = ticket.line_item_billing.is_a?(String) ? JSON.parse(ticket.line_item_billing) : ticket.line_item_billing
            
            # Ensure billing_data is a Hash, not an Array
            billing_data = nil unless billing_data.is_a?(Hash)
          rescue JSON::ParserError => e
            Rails.logger.error "Failed to parse line_item_billing for ticket #{ticket.id}: #{e.message}"
            billing_data = nil
          end
        end
        
        if billing_data.present? && billing_data.is_a?(Hash)
          # Safely iterate through parts
          parts_array.each_with_index do |part, index|
            begin
              parts_billing = billing_data['parts'] || {}
              billing = parts_billing[index.to_s] || {}
              
              if billing['billing_type'] == 'customer'
                customer_total += part['total'].to_f
              else
                warranty_total += part['total'].to_f
              end
            rescue => e
              Rails.logger.error "Error processing part billing for ticket #{ticket.id}, part #{index}: #{e.message}"
              customer_total += part['total'].to_f  # Default to customer if error
            end
          end
          
          # Safely iterate through labor
          labor_array.each_with_index do |labor, index|
            begin
              labor_billing = billing_data['labor'] || {}
              billing = labor_billing[index.to_s] || {}
              
              if billing['billing_type'] == 'customer'
                customer_total += labor['total'].to_f
              else
                warranty_total += labor['total'].to_f
              end
            rescue => e
              Rails.logger.error "Error processing labor billing for ticket #{ticket.id}, labor #{index}: #{e.message}"
              customer_total += labor['total'].to_f  # Default to customer if error
            end
          end
        else
          # No billing set yet, show full amount as customer total
          customer_total = parts_array.sum { |p| p['total'].to_f } + labor_array.sum { |l| l['total'].to_f }
        end
        
        data = {
          id: ticket.id,
          title: ticket.title,
          description: ticket.description,
          status: ticket.status,
          priority: ticket.priority,
          scheduledDate: ticket.scheduled_date,
          completedDate: ticket.completed_date,
          portalNotes: ticket.portal_notes,
          homeInfo: ticket.home_info,
          notes: ticket.notes, # Staff customer notes - always visible to portal
          isPortalCreated: ticket.is_portal_created,
          portalVisible: ticket.portal_visible,
          locationId: ticket.location_id,  # For debugging
          createdAt: ticket.created_at,
          updatedAt: ticket.updated_at,
          statusLabel: status_label(ticket.status),
          attachmentsCount: ticket.attachments.count,
          # ALWAYS include cost breakdown (not just in details)
          customerTotal: customer_total,
          warrantyTotal: warranty_total,
          totalCost: customer_total + warranty_total
        }
        
        if include_details
          data[:assignedTo] = ticket.assigned_to
          
          # Include parts and labor arrays in detail view
          data[:parts] = parts_array
          data[:labor] = labor_array
          
          # Include attachment URLs for viewing
          data[:attachments] = ticket.attachments.map do |attachment|
            {
              id: attachment.id,
              filename: attachment.filename.to_s,
              contentType: attachment.content_type,
              byteSize: attachment.byte_size,
              url: Rails.application.routes.url_helpers.rails_blob_url(attachment, only_path: true)
            }
          end
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
