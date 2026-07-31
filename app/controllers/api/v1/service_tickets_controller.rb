# frozen_string_literal: true

module Api
  module V1
    class ServiceTicketsController < ApplicationController
      before_action :set_company
      before_action :set_service_ticket, only: [:show, :update, :destroy, :upload_attachments, :set_attachment_audience, :mark_warranty_suspected, :mark_warranty, :unmark_warranty, :set_line_billing, :generate_customer_invoice, :generate_warranty_claim, :generate_both, :assign_contractor, :unassign_contractor]
      
      # GET /api/v1/service-tickets
      def index
        return unless authorize_action!('service', 'read')
        
        # STRICT TENANT ISOLATION
        @service_tickets = if current_user.uses_rbac?
          if current_user.effective_admin?
            @company.service_tickets
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              @company.service_tickets.where(location_id: location_ids)
            else
              @company.service_tickets
            end
          end
        else
          @company.service_tickets
        end
        
        # Apply location selector filter
        if Current.location_filtered?
          @service_tickets = @service_tickets.where(location_id: Current.location_id)
        end
        
        @service_tickets = @service_tickets.includes(:account, :contact, :vehicle, :warranty_claim_owned).recent
        
        # Apply filters
        @service_tickets = @service_tickets.where(status: params[:status]) if params[:status].present?
        @service_tickets = @service_tickets.where(priority: params[:priority]) if params[:priority].present?
        @service_tickets = @service_tickets.assigned_to(params[:assigned_to]) if params[:assigned_to].present?
        @service_tickets = @service_tickets.where(account_id: params[:account_id]) if params[:account_id].present?
        @service_tickets = @service_tickets.where(contact_id: params[:contact_id]) if params[:contact_id].present?
        @service_tickets = @service_tickets.where(vehicle_id: params[:vehicle_id]) if params[:vehicle_id].present?
        @service_tickets = @service_tickets.dealer_only if params[:dealer_only] == 'true'
        @service_tickets = @service_tickets.customer_facing if params[:dealer_only] == 'false'
        @service_tickets = @service_tickets.warranty_suspected if params[:warranty_suspected] == 'true'
        @service_tickets = @service_tickets.warranty_confirmed if params[:warranty_confirmed] == 'true'

        # Search across the whole result set, not just the page the client is
        # holding. The list is paginated at 50, and search used to run in the
        # browser over the loaded page only, so a ticket on page 2 could not be
        # found at all — it looked like the ticket did not exist.
        if params[:search].present?
          term = "%#{params[:search].to_s.strip}%"
          @service_tickets = @service_tickets
            .left_joins(:account)
            .where(
              'service_tickets.ticket_number ILIKE :t OR service_tickets.title ILIKE :t ' \
              'OR service_tickets.description ILIKE :t OR service_tickets.assigned_to ILIKE :t ' \
              'OR accounts.name ILIKE :t OR CAST(service_tickets.id AS TEXT) ILIKE :t',
              t: term
            )
            .distinct
        end

        # Pagination
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i
        per_page = [per_page, 200].min  # Cap at 200
        total = @service_tickets.count
        @service_tickets = @service_tickets.offset((page - 1) * per_page).limit(per_page)
        
        render json: {
          data: @service_tickets.map { |ticket| serialize_ticket(ticket) },
          meta: {
            total: total,
            page: page,
            per_page: per_page,
            total_pages: (total.to_f / per_page).ceil
          }
        }
      end
      
      # GET /api/v1/service-tickets/:id
      def show
        return unless authorize_action!('service', 'read')
        
        render json: {
          data: serialize_ticket(@service_ticket, include_attachments: true)
        }
      end
      
      # POST /api/v1/service-tickets
      def create
        return unless authorize_action!('service', 'create')
        
        @service_ticket = @company.service_tickets.new(service_ticket_params)
        
        # Auto-assign location from selector
        @service_ticket.location_id ||= Current.location_id if Current.location_id.present?
        
        # RBAC fallback
        if @service_ticket.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          @service_ticket.location_id ||= location_ids.first if location_ids.any?
        end
        
        if @service_ticket.save
          # Assignment notification handled by model callback (NotifiableServiceTicket)
          # which also checks skip_notifications and prevents self-notification
          
          render json: { data: serialize_ticket(@service_ticket) }, status: :created
        else
          render json: { errors: @service_ticket.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH/PUT /api/v1/service-tickets/:id
      def update
        return unless authorize_action!('service', 'update')
        
        # Track changes for notifications
        old_status = @service_ticket.status
        old_assigned_to = @service_ticket.assigned_to
        
        # Set model-level flag to skip after_update callbacks for bulk operations
        @service_ticket.skip_notifications = true if params[:skip_notification].present?

        if @service_ticket.update(service_ticket_params)
          # Assignment/reassignment notifications handled by model callback (NotifiableServiceTicket)
          # which also checks skip_notifications and prevents self-notification.
          # Controller only handles status-change notifications that the model doesn't cover.
          unless params[:skip_notification].present?
            # Notify contact owner on completion (model handles creator notification separately)
            if old_status != 'completed' && @service_ticket.status == 'completed'
              if @service_ticket.contact_id.present?
                contact = Contact.find_by(id: @service_ticket.contact_id)
                if contact && contact.owner_id.present?
                  owner = User.find_by(id: contact.owner_id)
                  # Never notify yourself
                  if owner && owner.id != current_user&.id
                    trigger_notification(
                      :service_ticket_completed,
                      recipient: owner,
                      notifiable: @service_ticket,
                      message: "Service ticket ##{@service_ticket.id} '#{@service_ticket.title}' has been completed."
                    )
                  end
                end
              end
            # Notify assigned user on other status changes
            elsif old_status != @service_ticket.status
              if @service_ticket.assigned_to.present?
                assigned_user = User.find_by(id: @service_ticket.assigned_to)
                # Never notify yourself
                if assigned_user && assigned_user.id != current_user&.id
                  trigger_notification(
                    :service_ticket_updated,
                    recipient: assigned_user,
                    notifiable: @service_ticket,
                    message: "Service ticket ##{@service_ticket.id} status changed from #{old_status} to #{@service_ticket.status}."
                  )
                end
              end
            end
          end
          
          render json: { data: serialize_ticket(@service_ticket) }
        else
          render json: { errors: @service_ticket.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/service-tickets/:id
      # Pass ?cascade=true to also clear an attached draft warranty claim (+ its
      # draft invoice) before deletion. Non-draft claims / finalized invoices
      # are still refused by unmark_warranty!. On cascade the claim row is
      # hard-deleted (not just soft-deleted) so the ticket FK is released.
      def destroy
        return unless authorize_action!('service', 'delete')

        if ActiveModel::Type::Boolean.new.cast(params[:cascade])
          status, reason = @service_ticket.unmark_warranty!
          if status == :blocked
            return render json: { errors: [reason] }, status: :unprocessable_entity
          end
          # unmark_warranty! soft-deletes the claim; hard-delete it now so the
          # service_tickets ↔ warranty_claims FK doesn't block ticket destroy.
          WarrantyClaim.where(service_ticket_id: @service_ticket.id).destroy_all
        end

        if @service_ticket.destroy
          head :no_content
        else
          render json: { errors: @service_ticket.errors.full_messages },
                 status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/service-tickets/:id/upload-attachments
      # Upload photos/videos for service ticket
      def upload_attachments
        return unless authorize_action!('service', 'update')
        
        if params[:files].present?
          # Track which attachments are newly created so we can default their
          # sharing audience to BOTH customer and manufacturer.
          existing_ids = @service_ticket.attachments.map(&:id)
          params[:files].each do |file|
            @service_ticket.attachments.attach(file)
          end

          new_attachments = @service_ticket.attachments.reject { |a| existing_ids.include?(a.id) }
          new_attachments.each do |attachment|
            AttachmentAudience.find_or_create_by(active_storage_attachment_id: attachment.id) do |a|
              a.visible_to_customer = true
              a.visible_to_manufacturer = true
              a.tagged_by_id = current_user&.id
            end
          end

          render json: {
            data: serialize_ticket(@service_ticket, include_attachments: true),
            message: 'Files uploaded successfully'
          }
        else
          render json: { errors: ['No files provided'] }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/service-tickets/:id/attachments/:attachment_id/audience
      # Tag who an attachment is visible to (customer / manufacturer). Internal
      # staff always have access regardless of these flags.
      def set_attachment_audience
        return unless authorize_action!('service', 'update')

        attachment = @service_ticket.attachments.find_by(id: params[:attachment_id])
        return render json: { error: 'Attachment not found' }, status: :not_found unless attachment

        audience = AttachmentAudience.find_or_initialize_by(active_storage_attachment_id: attachment.id)
        bool = ActiveModel::Type::Boolean.new
        audience.visible_to_customer = bool.cast(params[:visible_to_customer]) unless params[:visible_to_customer].nil?
        audience.visible_to_manufacturer = bool.cast(params[:visible_to_manufacturer]) unless params[:visible_to_manufacturer].nil?
        audience.tagged_by_id = current_user&.id
        audience.save!

        render json: { data: serialize_attachment(attachment) }
      end

      # POST /api/v1/service-tickets/:id/mark-warranty-suspected
      # Client or company marks ticket as potential warranty issue
      def mark_warranty_suspected
        return unless authorize_action!('service', 'update')
        
        if @service_ticket.mark_warranty_suspected!
          render json: {
            data: serialize_ticket(@service_ticket),
            message: 'Ticket marked as warranty suspected'
          }
        else
          render json: { errors: ['Unable to mark ticket'] }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/service-tickets/:id/mark-warranty
      # Mark ticket as a warranty claim and create (or reuse) its single draft
      # claim. Manufacturer is required. No invoice is generated here; line items
      # are tagged afterward and the invoice is generated at submit/generate time.
      def mark_warranty
        return unless authorize_action!('service', 'update')

        unless params[:manufacturer_id].present?
          return render json: { error: 'Manufacturer is required to mark a ticket as warranty' }, status: :unprocessable_entity
        end

        begin
          claim = @service_ticket.mark_as_warranty!(
            manufacturer_id: params[:manufacturer_id],
            marked_by: current_user.email
          )
          render json: {
            success: true,
            data: serialize_ticket(@service_ticket.reload),
            claim: serialize_warranty_claim(claim),
            message: 'Ticket marked as warranty; draft claim ready'
          }
        rescue => e
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/service-tickets/:id/unmark-warranty
      # Gated cascade un-mark (see ServiceTicket#unmark_warranty!). Only allowed
      # while the claim and its warranty invoice are still draft.
      def unmark_warranty
        return unless authorize_action!('service', 'update')

        result, reason = @service_ticket.unmark_warranty!
        if result == :ok
          render json: {
            success: true,
            data: serialize_ticket(@service_ticket.reload),
            message: 'Warranty removed from ticket'
          }
        else
          render json: { error: reason }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/service-tickets/:id/set-line-billing
      # Set billing type (warranty vs customer) for a specific line item
      def set_line_billing
        return unless authorize_action!('service', 'update')

        begin
          @service_ticket.set_line_billing(
            index: params[:index].to_i,
            type: params[:type],
            billing_type: params[:billing_type],
            manufacturer_id: params[:manufacturer_id]
          )

          @service_ticket.reload

          render json: {
            success: true,
            data: serialize_ticket(@service_ticket),
            message: "Line item marked as #{params[:billing_type]}"
          }
        rescue => e
          Rails.logger.error "❌ [set_line_billing] Error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/service-tickets/:id/generate-customer-invoice
      # Generate invoice for customer-pay items only
      def generate_customer_invoice
        return unless authorize_action!('service', 'update')
        
        unless @service_ticket.has_customer_items?
          return render json: { error: 'No customer items to invoice' }, status: :unprocessable_entity
        end
        
        begin
          service = ServiceTicketInvoiceService.new(@service_ticket)
          invoice = service.generate_customer_invoice
          
          render json: {
            success: true,
            invoice: serialize_invoice(invoice),
            message: 'Customer invoice generated successfully'
          }, status: :created
        rescue => e
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/service-tickets/:id/generate-warranty-claim
      # Generate warranty claim and invoice for warranty items only
      def generate_warranty_claim
        return unless authorize_action!('service', 'update')
        
        unless @service_ticket.has_warranty_items?
          return render json: { error: 'No warranty items selected' }, status: :unprocessable_entity
        end
        
        unless params[:manufacturer_id].present?
          return render json: { error: 'Manufacturer ID required' }, status: :unprocessable_entity
        end
        
        begin
          # Reuse existing draft claim if one already exists (idempotent); else
          # create. The DB unique index also guarantees one active claim/ticket.
          claim = @service_ticket.warranty_claim_owned
          if claim
            if claim.draft?
              claim.update!(
                manufacturer_id: params[:manufacturer_id],
                parts: @service_ticket.warranty_parts,
                labor: @service_ticket.warranty_labor,
                estimated_amount: @service_ticket.warranty_total,
                notes_to_manufacturer: params[:notes_to_manufacturer]
              )
            end
          else
            claim = WarrantyClaim.create!(
              company_id: @service_ticket.company_id,
              location_id: @service_ticket.location_id,
              service_ticket_id: @service_ticket.id,
              manufacturer_id: params[:manufacturer_id],
              parts: @service_ticket.warranty_parts,
              labor: @service_ticket.warranty_labor,
              estimated_amount: @service_ticket.warranty_total,
              notes_to_manufacturer: params[:notes_to_manufacturer],
              submitted_by: current_user.email,
              status: 'draft'
            )
          end

          # Manufacturer-tagged ticket files flow to the claim live via
          # WarrantyClaim#manufacturer_attachments — no copy/snapshot needed.

          # Update service ticket
          @service_ticket.update!(
            warranty_claim_id: claim.id,
            is_warranty_confirmed: true
          )

          # Generate warranty invoice
          service = ServiceTicketInvoiceService.new(@service_ticket)
          invoice = service.generate_warranty_invoice(claim)
          
          render json: {
            success: true,
            claim: serialize_warranty_claim(claim),
            invoice: serialize_invoice(invoice),
            message: 'Warranty claim and invoice generated successfully'
          }, status: :created
        rescue => e
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/service-tickets/:id/generate-both
      # Generate both customer invoice and warranty claim (if applicable)
      def generate_both
        return unless authorize_action!('service', 'update')
        
        result = {}
        
        begin
          # Generate customer invoice if there are customer items
          if @service_ticket.has_customer_items?
            service = ServiceTicketInvoiceService.new(@service_ticket)
            result[:customer_invoice] = service.generate_customer_invoice
          end
          
          # Generate warranty claim if there are warranty items
          if @service_ticket.has_warranty_items?
            unless params[:manufacturer_id].present?
              return render json: { error: 'Manufacturer ID required for warranty items' }, status: :unprocessable_entity
            end
            
            claim = @service_ticket.warranty_claim_owned
            if claim
              if claim.draft?
                claim.update!(
                  manufacturer_id: params[:manufacturer_id],
                  parts: @service_ticket.warranty_parts,
                  labor: @service_ticket.warranty_labor,
                  estimated_amount: @service_ticket.warranty_total,
                  notes_to_manufacturer: params[:notes_to_manufacturer]
                )
              end
            else
              claim = WarrantyClaim.create!(
                company_id: @service_ticket.company_id,
                location_id: @service_ticket.location_id,
                service_ticket_id: @service_ticket.id,
                manufacturer_id: params[:manufacturer_id],
                parts: @service_ticket.warranty_parts,
                labor: @service_ticket.warranty_labor,
                estimated_amount: @service_ticket.warranty_total,
                notes_to_manufacturer: params[:notes_to_manufacturer],
                submitted_by: current_user.email,
                status: 'draft'
              )
            end

            # Manufacturer-tagged ticket files flow to the claim live via
            # WarrantyClaim#manufacturer_attachments — no copy/snapshot needed.

            @service_ticket.update!(
              warranty_claim_id: claim.id,
              is_warranty_confirmed: true
            )

            service = ServiceTicketInvoiceService.new(@service_ticket)
            result[:warranty_invoice] = service.generate_warranty_invoice(claim)
            result[:warranty_claim] = claim
          end
          
          render json: {
            success: true,
            customer_invoice: result[:customer_invoice] ? serialize_invoice(result[:customer_invoice]) : nil,
            warranty_invoice: result[:warranty_invoice] ? serialize_invoice(result[:warranty_invoice]) : nil,
            warranty_claim: result[:warranty_claim] ? serialize_warranty_claim(result[:warranty_claim]) : nil,
            message: 'Invoices generated successfully'
          }, status: :created
        rescue => e
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/service-tickets/:id/assign-contractor
      def assign_contractor
        return unless authorize_action!('contractors', 'create')

        contractor = @company.contractors.where(status: 'active').where(is_deleted: [false, nil]).find(params[:contractor_id])

        existing = @service_ticket.contractor_assignments.find_by(contractor_id: contractor.id)
        if existing
          return render json: { error: 'Contractor already assigned to this ticket' }, status: :unprocessable_entity
        end

        assignment = @service_ticket.contractor_assignments.build(
          contractor: contractor,
          company: @company,
          assigned_by: current_user,
          status: 'assigned',
          assigned_at: Time.current,
          notes: params[:notes]
        )

        if assignment.save
          render json: {
            data: serialize_ticket(@service_ticket.reload, include_attachments: false)
          }, status: :created
        else
          render json: { errors: assignment.errors.full_messages }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Contractor not found' }, status: :not_found
      end

      # DELETE /api/v1/service-tickets/:id/unassign-contractor
      def unassign_contractor
        return unless authorize_action!('contractors', 'delete')

        assignment = @service_ticket.contractor_assignments.find_by!(contractor_id: params[:contractor_id])
        assignment.destroy

        render json: {
          data: serialize_ticket(@service_ticket.reload, include_attachments: false)
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Assignment not found' }, status: :not_found
      end

      # GET /api/v1/service-tickets/stats
      def stats
        return unless authorize_action!('service', 'read')

        tickets = @company.service_tickets

        # Apply account filter if provided
        if params[:account_id].present?
          tickets = tickets.where(account_id: params[:account_id])
        end

        # RBAC location filtering: mirror the index action so non-admins don't
        # see counts across locations they can't otherwise access.
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          tickets = location_ids.any? ? tickets.where(location_id: location_ids) : tickets.none
        end

        # Apply location selector filter for stats
        if Current.location_filtered?
          tickets = tickets.where(location_id: Current.location_id)
        end

        stats_data = {
          total: tickets.count,
          open: tickets.open.count,
          in_progress: tickets.in_progress.count,
          waiting_on_manufacturer: tickets.waiting_on_manufacturer.count,
          completed: tickets.completed.count,
          overdue: tickets.where('scheduled_date < ? AND status != ?', Date.today, 'completed').count,
          warranty_suspected: tickets.warranty_suspected.count,
          warranty_confirmed: tickets.warranty_confirmed.count,
          total_revenue: tickets.sum { |t| t.total_cost }
        }

        render json: { data: stats_data }
      end
      
      private
      
      def set_service_ticket
        @service_ticket = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
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
        unless current_user
          Rails.logger.error "🚫 [ServiceTicketsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
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
      end
      
      def service_ticket_params
        params.require(:service_ticket).permit(
          :account_id,
          :contact_id,
          :vehicle_id,
          :deal_id,
          :home_info,
          :title,
          :description,
          :status,
          :priority,
          :assigned_to,
          :scheduled_date,
          :notes,
          :is_warranty_suspected,
          :is_warranty_confirmed,
          :portal_user_id,
          :is_portal_created,
          :portal_notes,
          :portal_visible,  # Allow customer to view this ticket in portal
          :dealer_only,     # Internal pre-sale ticket (no customer); hidden from portal
          :factory_po,
          parts: [:id, :part_number, :partNumber, :description, :quantity, :unit_cost, :unitCost, :total, :part_id, :partId],
          labor: [:id, :description, :hours, :rate, :total],
          custom_fields: {},
          line_item_billing: [:index, :type, :billing_type, :manufacturer_id]
        )
      end
      
      def serialize_ticket(ticket, include_attachments: false)
        parts_array = ticket.parts.is_a?(Array) ? ticket.parts : (ticket.parts.present? ? (JSON.parse(ticket.parts) rescue []) : [])
        labor_array = ticket.labor.is_a?(Array) ? ticket.labor : (ticket.labor.present? ? (JSON.parse(ticket.labor) rescue []) : [])
        custom_fields_hash = ticket.custom_fields.is_a?(Hash) ? ticket.custom_fields : (ticket.custom_fields.present? ? (JSON.parse(ticket.custom_fields) rescue {}) : {})
        
        line_item_billing_array = ticket.line_item_billing.is_a?(Array) ? ticket.line_item_billing : (ticket.line_item_billing.present? ? (JSON.parse(ticket.line_item_billing) rescue []) : [])
        
        data = {
          id: ticket.id,
          ticketNumber: ticket.ticket_number,  # Add ticket number to API response
          accountId: ticket.account_id,
          contactId: ticket.contact_id,
          vehicleId: ticket.vehicle_id,
          dealId: ticket.deal_id,
          homeInfo: ticket.home_info,
          title: ticket.title,
          description: ticket.description,
          status: ticket.status,
          priority: ticket.priority,
          assignedTo: ticket.assigned_to,
          factoryPo: ticket.factory_po,
          assignedToUser: ticket.assigned_to.present? ? serialize_assigned_user(ticket.assigned_to) : nil,
          scheduledDate: ticket.scheduled_date,
          notes: ticket.notes,
          parts: parts_array,
          labor: labor_array,
          customFields: custom_fields_hash,
          lineItemBilling: line_item_billing_array,
          portalUserId: ticket.portal_user_id,
          isPortalCreated: ticket.is_portal_created,
          portalNotes: ticket.portal_notes,
          portalVisible: ticket.portal_visible,  # Allow customer to view checkbox
          dealerOnly: ticket.dealer_only,
          warrantySuspected: ticket.is_warranty_suspected,
          warrantyConfirmed: ticket.is_warranty_confirmed,
          warrantyClaimId: ticket.warranty_claim_id,
          hasWarrantyItems: ticket.has_warranty_items?,
          hasCustomerItems: ticket.has_customer_items?,
          warrantyTotal: ticket.warranty_total,
          customerTotal: ticket.customer_total,
          createdAt: ticket.created_at,
          updatedAt: ticket.updated_at,
          account: ticket.account ? {
            id: ticket.account.id,
            name: ticket.account.name
          } : nil,
          contact: ticket.contact ? {
            id: ticket.contact.id,
            firstName: ticket.contact.first_name,
            lastName: ticket.contact.last_name,
            email: ticket.contact.email,
            phone: ticket.contact.phone
          } : nil,
          vehicle: ticket.vehicle ? {
            id: ticket.vehicle.id,
            year: ticket.vehicle.year,
            make: ticket.vehicle.make,
            model: ticket.vehicle.model
          } : nil,
          warrantyClaim: ticket.warranty_claim_owned ? {
            id: ticket.warranty_claim_owned.id,
            claimNumber: ticket.warranty_claim_owned.claim_number,
            status: ticket.warranty_claim_owned.status,
            estimatedAmount: ticket.warranty_claim_owned.estimated_amount
          } : nil
        }
        
        if include_attachments
          data[:attachments] = ticket.attachments.map { |a| serialize_attachment(a) }
          data[:attachmentsCount] = ticket.attachments.count
        else
          data[:attachmentsCount] = ticket.attachments.count
        end
        
        # Load generated invoices for this ticket
        invoices = @company.invoices.where(source_type: 'ServiceTicket', source_id: ticket.id)
        data[:customerInvoice] = invoices.find { |i| i.billing_category == 'customer' }&.then do |inv|
          serialize_invoice(inv)
        end
        data[:warrantyInvoice] = invoices.find { |i| i.billing_category == 'warranty' }&.then do |inv|
          serialize_invoice(inv)
        end
        
        # Include warranty claim details if present
        data[:warrantyClaim] = ticket.warranty_claim_owned ? serialize_warranty_claim(ticket.warranty_claim_owned) : nil

        # Contractor assignments (Phase 2B)
        data[:contractorAssignments] = ticket.contractor_assignments.includes(:contractor).map do |ca|
          {
            id: ca.id,
            status: ca.status,
            assignedAt: ca.assigned_at,
            notes: ca.notes,
            contractor: {
              id: ca.contractor.id,
              name: ca.contractor.name,
              contactName: ca.contractor.contact_name,
              tradeType: ca.contractor.trade_type,
              phone: ca.contractor.phone,
              email: ca.contractor.email
            }
          }
        end

        data
      end
      
      def serialize_assigned_user(user_id)
        user = User.find_by(id: user_id)
        return nil unless user
        
        {
          id: user.id,
          name: user.name,
          firstName: user.first_name,
          lastName: user.last_name,
          email: user.email
        }
      end
      
      def serialize_attachment(attachment)
        audience = AttachmentAudience.find_by(active_storage_attachment_id: attachment.id)
        {
          id: attachment.id,
          filename: attachment.filename.to_s,
          contentType: attachment.content_type,
          byteSize: attachment.byte_size,
          url: rails_blob_url(attachment, only_path: true),
          visibleToCustomer: audience&.visible_to_customer || false,
          visibleToManufacturer: audience&.visible_to_manufacturer || false
        }
      end
      
      def serialize_invoice(invoice)
        # Include recipient details based on type
        recipient_data = if invoice.recipient_type == 'Manufacturer' && invoice.recipient_id.present?
          manufacturer = Manufacturer.find_by(id: invoice.recipient_id)
          manufacturer ? {
            id: manufacturer.id,
            name: manufacturer.name,
            type: 'Manufacturer'
          } : nil
        elsif invoice.recipient_type == 'Contact' && invoice.contact_id.present?
          contact = Contact.find_by(id: invoice.contact_id)
          contact ? {
            id: contact.id,
            firstName: contact.first_name,
            lastName: contact.last_name,
            type: 'Contact'
          } : nil
        else
          nil
        end
        
        {
          id: invoice.id,
          invoiceNumber: invoice.invoice_number,
          invoiceDate: invoice.invoice_date,
          dueDate: invoice.due_date,
          status: invoice.status,
          billingCategory: invoice.billing_category,
          subtotal: invoice.subtotal,
          taxRate: invoice.tax_rate,
          taxAmount: invoice.tax_amount,
          total: invoice.total,
          amountDue: invoice.amount_due,
          amountPaid: invoice.amount_paid,
          notes: invoice.notes,
          sourceType: invoice.source_type,
          sourceId: invoice.source_id,
          recipientType: invoice.recipient_type,
          recipientId: invoice.recipient_id,
          recipient: recipient_data,
          contactId: invoice.contact_id,
          createdAt: invoice.created_at,
          updatedAt: invoice.updated_at
        }
      end
      
      def serialize_warranty_claim(claim)
        {
          id: claim.id,
          claimNumber: claim.claim_number,
          status: claim.status,
          manufacturerId: claim.manufacturer_id,
          serviceTicketId: claim.service_ticket_id,
          estimatedAmount: claim.estimated_amount,
          approvedAmount: claim.approved_amount,
          parts: claim.parts,
          labor: claim.labor,
          notesToManufacturer: claim.notes_to_manufacturer,
          submittedBy: claim.submitted_by,
          submittedAt: claim.submitted_at,
          createdAt: claim.created_at,
          updatedAt: claim.updated_at
        }
      end
    end
  end
end
