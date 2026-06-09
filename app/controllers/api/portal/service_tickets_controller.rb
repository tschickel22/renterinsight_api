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
      
      # POST /api/portal/service-tickets/:id/notes
      # Lets a customer reply to the customer-facing note thread on their ticket.
      def notes
        ticket = ServiceTicket
          .where(company_id: current_portal_user.company_id)
          .where(portal_visible: true)
          .where("account_id = ? OR contact_id = ?",
                 current_portal_user.buyer_id,
                 current_portal_user.buyer_id)
          .find(params[:id])

        content = params.dig(:note, :content) || params[:content]
        if content.blank?
          return render json: { error: 'Note content is required' }, status: :unprocessable_entity
        end

        note = Note.new(
          entity_type: 'service_ticket',
          entity_id: ticket.id.to_s,
          category: 'customer',
          author_type: 'customer',
          content: content.to_s.strip,
          created_by_name: portal_user_display_name
        )

        if note.save
          render json: {
            success: true,
            data: {
              id: note.id,
              content: note.content,
              authorType: note.author_type,
              createdAt: note.created_at,
              createdByName: note.created_by_name
            }
          }, status: :created
        else
          render json: { success: false, errors: note.errors.full_messages }, status: :unprocessable_entity
        end
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
        
        # Auto-assign to appropriate staff member (triggers notification via NotifiableServiceTicket)
        # Fallback chain: Location setting → Contact owner → Account owner → First active user at company
        assignee = nil

        # Step 1: Check location-level default assignee setting
        if ticket.location_id.present?
          default_assignee_setting = Setting.get('Location', ticket.location_id, 'default_service_ticket_assignee')
          if default_assignee_setting.present?
            default_user_id = default_assignee_setting.is_a?(Hash) ? default_assignee_setting['user_id'] : default_assignee_setting
            assignee = User.find_by(id: default_user_id, status: 'active') if default_user_id.present?
            Rails.logger.info "[Portal ST Auto-Assign] Step 1 (location setting): #{assignee&.email || 'none'}"
          end
        end

        # Step 2: Contact owner
        unless assignee
          contact = current_portal_user.buyer if current_portal_user.buyer_type == 'Contact'
          assignee = contact&.owner if contact&.owner&.active?
          Rails.logger.info "[Portal ST Auto-Assign] Step 2 (contact owner): #{assignee&.email || 'none'} (contact #{contact&.id} owner_id: #{contact&.owner_id})"
        end

        # Step 3: Account owner
        unless assignee
          assignee = account.owner if account.owner&.active?
          Rails.logger.info "[Portal ST Auto-Assign] Step 3 (account owner): #{assignee&.email || 'none'} (account #{account.id} owner_id: #{account.owner_id})"
        end

        # Step 4: First active admin/manager at company (broad role match)
        unless assignee
          company = ::Company.find_by(id: current_portal_user.company_id)
          if company
            assignee = company.users
              .where(status: 'active')
              .where.not(role: ['client', 'portal'])
              .order(:id)
              .first
            Rails.logger.info "[Portal ST Auto-Assign] Step 4 (first active staff): #{assignee&.email || 'none'} (role: #{assignee&.role})"
          end
        end
        
        if assignee
          ticket.assigned_to = assignee.id.to_s
          Rails.logger.info "[Portal ST Auto-Assign] ✅ Assigned to: #{assignee.email} (id: #{assignee.id})"
        else
          Rails.logger.warn "[Portal ST Auto-Assign] ⚠️ No assignee found for portal ticket"
        end
        
        if ticket.save
          # Handle file attachments if provided
          if params[:files].present?
            params[:files].each do |file|
              ticket.attachments.attach(file)
            end
          end
          
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

      # Best-effort display name for a portal (customer) author on a note.
      def portal_user_display_name
        buyer = current_portal_user.buyer
        if buyer.respond_to?(:first_name) || buyer.respond_to?(:last_name)
          name = "#{buyer.try(:first_name)} #{buyer.try(:last_name)}".strip
          return name if name.present?
        end
        return buyer.name if buyer.respond_to?(:name) && buyer.name.present?
        current_portal_user.try(:email).presence || 'Customer'
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

          # Customer-facing notes (timestamped/user-stamped). Technician notes are
          # internal and intentionally excluded from the portal.
          data[:customerNotes] = Note
            .for_entity('service_ticket', ticket.id.to_s)
            .where(category: 'customer')
            .recent
            .map do |n|
              {
                id: n.id,
                content: n.content,
                authorType: n.author_type,
                createdAt: n.created_at,
                createdByName: n.created_by_name
              }
            end
          
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
