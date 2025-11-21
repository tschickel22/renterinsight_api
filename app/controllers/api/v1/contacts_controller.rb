# frozen_string_literal: true

module Api
  module V1
    class ContactsController < ApplicationController
      before_action :set_company_scope
      before_action :set_contact, only: [:show, :update, :destroy, :add_tags, :remove_tag, :opt_in_email, :opt_out_email, :opt_in_sms, :opt_out_sms, :deals, :quotes, :portal_status]
      before_action :set_account, only: [:index]

      # GET /api/v1/contacts
      # GET /api/v1/accounts/:account_id/contacts
      def index
        return unless authorize_action!('crm', 'read')
        
        # STRICT TENANT ISOLATION: Only show contacts from current company
        # RBAC: Location-tier users only see their assigned locations
        @contacts = if @account
                      @account.contacts
                    else
                      if current_user.uses_rbac?
                        if current_user.effective_admin?  # Use RBAC-aware admin check
                          @company.contacts
                        else
                          location_ids = permission_service.accessible_location_ids
                          if location_ids.any?
                            # Include contacts in assigned locations OR unassigned contacts (NULL location_id)
                            @company.contacts.where("location_id IN (?) OR location_id IS NULL", location_ids)
                          else
                            @company.contacts
                          end
                        end
                      else
                        @company.contacts
                      end
                    end

        # Apply filters
        @contacts = apply_filters(@contacts)

        # Apply search
        @contacts = @contacts.search(params[:search]) if params[:search].present?

        # Apply sorting
        @contacts = apply_sorting(@contacts)

        # Pagination
        page = params[:page]&.to_i || 1
        per_page = params[:per_page]&.to_i || 50
        per_page = [per_page, 100].min # Cap at 100
        
        total_count = @contacts.count
        total_pages = (total_count.to_f / per_page).ceil
        offset = (page - 1) * per_page
        
        @contacts = @contacts.limit(per_page).offset(offset)

        render json: {
          contacts: @contacts.map { |contact| contact_json(contact) },
          meta: {
            current_page: page,
            total_pages: total_pages,
            total_count: total_count,
            per_page: per_page
          }
        }
      rescue => e
        Rails.logger.error "Error in contacts#index: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # GET /api/v1/contacts/stats
      def stats
        return unless authorize_action!('crm', 'read')
        
        # STRICT TENANT ISOLATION: Only stats for current company
        render json: @company.contacts.statistics
      rescue => e
        Rails.logger.error "Error in contacts#stats: #{e.message}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # GET /api/v1/contacts/:id
      def show
        return unless authorize_action!('crm', 'read')
        
        render json: contact_json(@contact, detailed: true)
      end

      # POST /api/v1/contacts
      def create
        return unless authorize_action!('crm', 'create')
        
        # Extract tags from the contact params before creating
        tag_names = contact_params_with_extra[:tags] || []
        
        # STRICT TENANT ISOLATION: Create contact within current company
        @contact = @company.contacts.new(contact_params)
        
        # RBAC: Location-tier users auto-assign to their location
        if current_user.uses_rbac? && !current_user.effective_admin?  # Use RBAC-aware admin check
          location_ids = permission_service.accessible_location_ids
          @contact.location_id ||= location_ids.first if location_ids.any?
        end

        if @contact.save
          # Handle tags if provided
          handle_tags(@contact, tag_names) if tag_names.is_a?(Array) && tag_names.any?

          render json: contact_json(@contact, detailed: true), status: :created
        else
          render json: { errors: @contact.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error in contacts#create: #{e.message}\n#{e.backtrace.join("\n")}"
        Rails.logger.error "Params: #{params.inspect}"
        render json: { error: e.message, details: e.backtrace.first(5) }, status: :internal_server_error
      end

      # PATCH/PUT /api/v1/contacts/:id
      def update
        return unless authorize_action!('crm', 'update')
        
        # Extract tags from the contact params before updating
        tag_names = contact_params_with_extra[:tags]
        
        if @contact.update(contact_params)
          # Handle tags if provided
          handle_tags(@contact, tag_names) if tag_names

          render json: contact_json(@contact, detailed: true)
        else
          render json: { errors: @contact.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error in contacts#update: #{e.message}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # DELETE /api/v1/contacts/:id
      def destroy
        return unless authorize_action!('crm', 'delete')
        
        @contact.destroy
        head :no_content
      end

      # POST /api/v1/contacts/bulk_create
      def bulk_create
        return unless authorize_action!('crm', 'create')
        
        contacts_data = params[:contacts] || []
        created_contacts = []
        errors = []

        contacts_data.each_with_index do |contact_data, index|
          # STRICT TENANT ISOLATION: Create contacts within current company
          contact = @company.contacts.new(contact_data.permit(
            :account_id, :company_id, :first_name, :last_name, :email, :phone,
            :title, :department, :is_primary, :notes
          ))
          
          # RBAC: Location-tier users auto-assign to their location
          if current_user.uses_rbac? && !current_user.effective_admin?  # Use RBAC-aware admin check
            location_ids = permission_service.accessible_location_ids
            contact.location_id ||= location_ids.first if location_ids.any?
          end

          if contact.save
            created_contacts << contact
          else
            errors << { index: index, errors: contact.errors.full_messages }
          end
        end

        render json: {
          created: created_contacts.map { |c| contact_json(c) },
          errors: errors,
          summary: {
            total: contacts_data.length,
            created: created_contacts.length,
            failed: errors.length
          }
        }, status: (errors.any? ? :multi_status : :created)
      end

      # POST /api/v1/contacts/check_duplicate
      def check_duplicate
        return unless authorize_action!('crm', 'read')
        
        email = params[:email]&.strip&.downcase
        phone = params[:phone]&.strip
        
        if email.blank? && phone.blank?
          render json: { 
            duplicate_found: false,
            message: 'No email or phone provided'
          }
          return
        end

        # STRICT TENANT ISOLATION: Only check within current company
        query = @company.contacts
        
        conditions = []
        conditions << "LOWER(email) = ?" if email.present?
        conditions << "phone = ?" if phone.present?
        
        params_array = []
        params_array << email if email.present?
        params_array << phone if phone.present?
        
        existing_contact = query.where(conditions.join(' OR '), *params_array).first

        if existing_contact
          render json: {
            duplicate_found: true,
            contact: contact_json(existing_contact, detailed: false),
            matched_field: existing_contact.email&.downcase == email ? 'email' : 'phone'
          }
        else
          render json: {
            duplicate_found: false,
            message: 'No duplicate found'
          }
        end
      rescue => e
        Rails.logger.error "Error in contacts#check_duplicate: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # POST /api/v1/contacts/quick_create
      def quick_create
        return unless authorize_action!('crm', 'create')
        
        # STRICT TENANT ISOLATION: Create contact within current company
        contact_data = {
          first_name: params[:first_name]&.strip,
          last_name: params[:last_name]&.strip,
          email: params[:email]&.strip&.downcase,
          phone: params[:phone]&.strip,
          notes: params[:notes]&.strip
        }.compact

        if contact_data[:first_name].blank?
          render json: { 
            errors: ['First name is required'] 
          }, status: :unprocessable_entity
          return
        end

        if contact_data[:email].blank? && contact_data[:phone].blank?
          render json: { 
            errors: ['Email or phone is required'] 
          }, status: :unprocessable_entity
          return
        end

        # Check for duplicates before creating
        if contact_data[:email].present? || contact_data[:phone].present?
          query = @company.contacts
          conditions = []
          params_array = []
          
          if contact_data[:email].present?
            conditions << "LOWER(email) = ?"
            params_array << contact_data[:email]
          end
          
          if contact_data[:phone].present?
            conditions << "phone = ?"
            params_array << contact_data[:phone]
          end
          
          existing_contact = query.where(conditions.join(' OR '), *params_array).first
          
          if existing_contact
            render json: {
              duplicate_found: true,
              contact: contact_json(existing_contact, detailed: true),
              message: 'Contact already exists'
            }, status: :conflict
            return
          end
        end

        @contact = @company.contacts.new(contact_data)
        
        # RBAC: Location-tier users auto-assign to their location
        if current_user.uses_rbac? && !current_user.effective_admin?  # Use RBAC-aware admin check
          location_ids = permission_service.accessible_location_ids
          @contact.location_id ||= location_ids.first if location_ids.any?
        end

        if @contact.save
          Rails.logger.info "✅ [ContactsController] Quick-created contact: #{@contact.id} for company: #{@company.id}"
          render json: {
            success: true,
            contact: contact_json(@contact, detailed: true)
          }, status: :created
        else
          render json: { 
            errors: @contact.errors.full_messages 
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error in contacts#quick_create: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # POST /api/v1/contacts/:id/tags
      def add_tags
        return unless authorize_action!('crm', 'update')
        
        tag_names = params[:tags] || []
        added_tags = []

        tag_names.each do |tag_name|
          tag = Tag.find_or_create_by(name: tag_name.strip)
          unless @contact.tags.include?(tag)
            @contact.tags << tag
            added_tags << tag
          end
        end

        render json: {
          contact: contact_json(@contact, detailed: true),
          added_tags: added_tags.map { |t| { id: t.id, name: t.name } }
        }
      end

      # DELETE /api/v1/contacts/:id/tags/:tag_name
      def remove_tag
        return unless authorize_action!('crm', 'update')
        
        tag = @contact.tags.find_by(name: params[:tag_name])

        if tag
          @contact.tags.delete(tag)
          render json: { message: 'Tag removed successfully' }
        else
          render json: { error: 'Tag not found' }, status: :not_found
        end
      end

      # PATCH /api/v1/contacts/:id/opt_in_email
      def opt_in_email
        return unless authorize_action!('crm', 'update')
        
        @contact.opt_in_email!
        render json: {
          message: 'Contact opted in to email communications',
          contact: contact_json(@contact, detailed: true)
        }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/contacts/:id/opt_out_email
      def opt_out_email
        return unless authorize_action!('crm', 'update')
        
        @contact.opt_out_email!(params[:reason])
        render json: {
          message: 'Contact opted out of email communications',
          contact: contact_json(@contact, detailed: true)
        }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/contacts/:id/opt_in_sms
      def opt_in_sms
        return unless authorize_action!('crm', 'update')
        
        @contact.opt_in_sms!
        render json: {
          message: 'Contact opted in to SMS communications',
          contact: contact_json(@contact, detailed: true)
        }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/contacts/:id/opt_out_sms
      def opt_out_sms
        return unless authorize_action!('crm', 'update')
        
        @contact.opt_out_sms!(params[:reason])
        render json: {
          message: 'Contact opted out of SMS communications',
          contact: contact_json(@contact, detailed: true)
        }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/contacts/:id/deals
      def deals
        return unless authorize_action!('crm', 'read')
        
        if @contact.account.nil?
          render json: {
            success: true,
            deals: []
          }
          return
        end

        @deals = @contact.account.deals.order(created_at: :desc)
        
        render json: {
          success: true,
          deals: @deals.map { |deal| {
            id: deal.id,
            accountId: deal.account_id,
            leadId: deal.lead_id,
            title: deal.title,
            stage: deal.stage,
            amount: deal.amount_cents / 100.0,
            expectedCloseOn: deal.expected_close_on,
            createdAt: deal.created_at,
            updatedAt: deal.updated_at
          }}
        }
      rescue => e
        render json: { error: e.message }, status: :internal_server_error
      end

      # GET /api/v1/contacts/:id/quotes
      def quotes
        return unless authorize_action!('crm', 'read')
        
        @quotes = Quote.where(contact_id: @contact.id)
                       .or(Quote.where(account_id: @contact.account_id))
                       .where(is_deleted: false)
                       .order(created_at: :desc)
        
        render json: {
          success: true,
          quotes: @quotes.map { |quote| {
            id: quote.id,
            accountId: quote.account_id,
            contactId: quote.contact_id,
            quoteNumber: quote.quote_number,
            status: quote.status,
            subtotal: quote.subtotal,
            tax: quote.tax,
            total: quote.total,
            items: quote.items,
            validUntil: quote.valid_until,
            sentAt: quote.sent_at,
            viewedAt: quote.viewed_at,
            acceptedAt: quote.accepted_at,
            rejectedAt: quote.rejected_at,
            notes: quote.notes,
            createdAt: quote.created_at,
            updatedAt: quote.updated_at
          }}
        }
      rescue => e
        render json: { error: e.message }, status: :internal_server_error
      end

      # GET /api/v1/contacts/:id/portal_status
      def portal_status
        return unless authorize_action!('crm', 'read')
        
        # Find portal access for this contact
        portal_access = BuyerPortalAccess.find_by(
          buyer_id: @contact.id,
          buyer_type: 'Contact',
          company_id: current_company_id
        )

        if portal_access
          render json: {
            hasPortalAccess: true,
            status: portal_access.status&.downcase || 'pending',
            invitationSentAt: portal_access.invitation_sent_at,
            lastLoginAt: portal_access.last_login_at,
            portalUserId: portal_access.id,
            email: portal_access.email,
            role: portal_access.role
          }
        else
          render json: {
            hasPortalAccess: false,
            status: 'none'
          }
        end
      rescue => e
        Rails.logger.error "Error in contacts#portal_status: #{e.message}"
        render json: { error: e.message }, status: :internal_server_error
      end

      private

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [ContactsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [ContactsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [ContactsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [ContactsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end

      def set_contact
        # STRICT TENANT ISOLATION: Only access contacts in same company
        # RBAC: Location-tier users only access their assigned locations
        @contact = if current_user.uses_rbac? && !current_user.effective_admin?  # Use RBAC-aware admin check
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            # Include contacts in assigned locations OR unassigned contacts (NULL location_id)
            @company.contacts.where("location_id IN (?) OR location_id IS NULL", location_ids).find(params[:id])
          else
            @company.contacts.find(params[:id])
          end
        else
          @company.contacts.find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Contact not found or access denied' }, status: :not_found
        return
      end

      def set_account
        # STRICT TENANT ISOLATION: Only access accounts in same company
        @account = @company.accounts.find(params[:account_id]) if params[:account_id]
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Account not found or access denied' }, status: :not_found
        return
      end

      def contact_params
        # Transform camelCase keys to snake_case
        contact_data = params.require(:contact).to_unsafe_h
        transformed_params = transform_keys_to_snake_case(contact_data)
        
        ActionController::Parameters.new(transformed_params).permit(
          :account_id,
          :company_id,
          :first_name,
          :last_name,
          :email,
          :phone,
          :title,
          :department,
          :is_primary,
          :notes
        )
      end

      # Helper to access extra params like tags
      def contact_params_with_extra
        contact_data = params.require(:contact).to_unsafe_h
        transformed_params = transform_keys_to_snake_case(contact_data)
        
        ActionController::Parameters.new(transformed_params).permit(
          :account_id,
          :company_id,
          :first_name,
          :last_name,
          :email,
          :phone,
          :title,
          :department,
          :is_primary,
          :notes,
          tags: []
        )
      end

      # Transform camelCase keys to snake_case
      def transform_keys_to_snake_case(hash)
        hash.transform_keys { |key| key.to_s.underscore.to_sym }
      end

      def apply_filters(contacts)
        contacts = contacts.where(account_id: params[:account_id]) if params[:account_id].present?
        contacts = contacts.where(department: params[:department]) if params[:department].present?
        contacts = contacts.where(title: params[:title]) if params[:title].present?
        contacts = contacts.where(is_primary: params[:is_primary]) if params[:is_primary].present?
        contacts = contacts.with_email if params[:has_email] == 'true'
        contacts = contacts.with_phone if params[:has_phone] == 'true'

        # Tag filtering
        if params[:tag_ids].present?
          tag_ids = params[:tag_ids].split(',').map(&:to_i)
          contacts = contacts.joins(:tags).where(tags: { id: tag_ids }).distinct
        end

        contacts
      end

      def apply_sorting(contacts)
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc

        case sort_by
        when 'name'
          contacts.order(first_name: sort_order, last_name: sort_order)
        when 'email'
          contacts.order(email: sort_order)
        when 'updated_at'
          contacts.order(updated_at: sort_order)
        else
          contacts.order(created_at: sort_order)
        end
      end

      def contact_json(contact, detailed: false)
        json = {
          id: contact.id,
          accountId: contact.account_id,
          companyId: contact.company_id,
          firstName: contact.first_name,
          lastName: contact.last_name,
          fullName: contact.full_name,
          email: contact.email,
          phone: contact.phone,
          title: contact.title,
          department: contact.department,
          isPrimary: contact.is_primary,
          notes: contact.notes,
          optOutEmail: contact.opt_out_email,
          optOutEmailAt: contact.opt_out_email_at,
          optOutSms: contact.opt_out_sms,
          optOutSmsAt: contact.opt_out_sms_at,
          createdAt: contact.created_at,
          updatedAt: contact.updated_at
        }

        if detailed
          json.merge!(
            tags: contact.tags.map { |t| { id: t.id, name: t.name, color: t.color } },
            account: contact.account ? {
              id: contact.account.id,
              name: contact.account.name,
              status: contact.account.status
            } : nil,
            contactMethods: contact.contact_methods,
            notesCount: contact.note_records.count
          )
        end

        json
      end

      def handle_tags(contact, tag_names)
        # CRITICAL: Must be persisted before using associations
        return unless contact.persisted?
        return unless tag_names.is_a?(Array) && tag_names.any?

        # Remove existing tags not in the new list
        current_tag_names = contact.tags.pluck(:name)
        tags_to_remove = current_tag_names - tag_names
        tags_to_remove.each do |tag_name|
          tag = contact.tags.find_by(name: tag_name)
          contact.tags.delete(tag) if tag
        end

        # Add new tags (contact is saved, so associations work)
        tag_names.each do |tag_name|
          next if tag_name.blank?
          tag = Tag.find_or_create_by!(name: tag_name.strip)
          contact.tags << tag unless contact.tags.include?(tag)
        end
        
        # Reload to ensure fresh association data
        contact.reload
      rescue => e
        Rails.logger.error "Error in handle_tags: #{e.message}\n#{e.backtrace.join("\n")}"
        # Don't fail the whole request, just log the error
      end
    end
  end
end
