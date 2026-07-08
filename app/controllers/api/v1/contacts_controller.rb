# frozen_string_literal: true

module Api
  module V1
    class ContactsController < ApplicationController
      before_action :set_company_scope
      before_action :set_contact, only: [:show, :update, :destroy, :tags, :add_tags, :remove_tag, :opt_in_email, :opt_out_email, :opt_in_sms, :opt_out_sms, :deals, :quotes, :portal_status, :documents, :upload_documents]
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
                            # Strict location filtering - only assigned locations
                            @company.contacts.where(location_id: location_ids)
                          else
                            @company.contacts
                          end
                        end
                      else
                        @company.contacts
                      end
                    end

        # Apply strict location filter - only contacts explicitly assigned to selected location
        if Current.location_filtered?
          @contacts = @contacts.where(location_id: Current.location_id)
        end

        # Apply filters (except search)
        @contacts = apply_filters(@contacts)
        
        # Count stats BEFORE search filter (stats tiles should show ALL contacts)
        all_contacts_count = @contacts.count
        status_counts = {
          assigned: @contacts.where.not(account_id: nil).count,
          unassigned: @contacts.where(account_id: nil).count,
          with_email: @contacts.where.not(email: [nil, '']).count,
          with_phone: @contacts.where.not(phone: [nil, '']).count
        }

        # Apply search filter (searches first_name, last_name, email, phone, title, department)
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          @contacts = @contacts.where(
            "first_name ILIKE ? OR last_name ILIKE ? OR email ILIKE ? OR phone ILIKE ? OR title ILIKE ? OR department ILIKE ?",
            search_term, search_term, search_term, search_term, search_term, search_term
          )
        end

        # Apply sorting
        @contacts = apply_sorting(@contacts)

        # Count AFTER search filter (for pagination)
        filtered_count = @contacts.count
        
        # Paginate
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i
        per_page = [per_page, 200].min  # Cap at 200
        @contacts = @contacts.includes(:account, :tags).offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: @contacts.map { |contact| contact_json(contact) },
          meta: {
            total: filtered_count,  # For pagination (filtered results)
            page: page,
            per_page: per_page,
            total_pages: (filtered_count.to_f / per_page).ceil,
            stats: status_counts.merge(total: all_contacts_count)  # For tiles (unfiltered totals)
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
        contacts = @company.contacts
        
        # Apply strict location filter - only contacts explicitly assigned to selected location
        if Current.location_filtered?
          contacts = contacts.where(location_id: Current.location_id)
        end
        
        render json: contacts.statistics
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
        
        # HARD BLOCK on duplicate email (create only). Phone duplicates are a
        # soft warning surfaced by the frontend and are NOT blocked here.
        dup_email = contact_params[:email].to_s.strip.downcase
        if dup_email.present?
          existing = @company.contacts.where('LOWER(email) = ?', dup_email).first
          if existing
            render json: {
              error: 'A contact with this email already exists.',
              duplicate: {
                field: 'email',
                id: existing.id,
                firstName: existing.first_name,
                lastName: existing.last_name,
                email: existing.email,
                phone: existing.phone
              }
            }, status: :conflict
            return
          end
        end

        # STRICT TENANT ISOLATION: Create contact within current company
        @contact = @company.contacts.new(contact_params)
        
        # Auto-assign owner: account owner if available, otherwise current user
        if @contact.owner_id.blank?
          if @contact.account_id.present?
            account = @company.accounts.find_by(id: @contact.account_id)
            @contact.owner_id = account&.owner_id.presence || current_user&.id
          else
            @contact.owner_id = current_user&.id
          end
        end
        
        # Auto-assign location from selector (if user selected a specific location)
        Rails.logger.info "🔍 [ContactsController#create] Before auto-assign - Current.location_id: #{Current.location_id}, location_filtered: #{Current.location_filtered?}"
        @contact.location_id ||= Current.location_id if Current.location_id.present?
        Rails.logger.info "🔍 [ContactsController#create] After Current.location_id assign - contact.location_id: #{@contact.location_id}"
        
        # RBAC fallback: Location-tier users auto-assign to their first location if no selector
        if @contact.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          Rails.logger.info "🔍 [ContactsController#create] RBAC fallback - accessible_location_ids: #{location_ids}"
          @contact.location_id ||= location_ids.first if location_ids.any?
        end
        
        Rails.logger.info "🔍 [ContactsController#create] Final location_id before save: #{@contact.location_id}"

        # Validate only required fields that are visible in active layout
        layout_errors = validate_visible_required_fields('contacts', @contact)
        if layout_errors.any?
          Rails.logger.error "[ContactsController#create] Layout validation failed: #{layout_errors.join(', ')}"
          render json: {
            errors: layout_errors
          }, status: :unprocessable_entity
          return
        end

        if @contact.save(validate: false)  # Skip model validations, we validated above
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
        
        # Handle custom_field_values merge (partial update pattern)
        update_attrs = contact_params
        custom_field_values_param = params[:custom_field_values] || params[:contact]&.dig(:custom_field_values)
        if custom_field_values_param.present?
          existing = @contact.custom_field_values || {}
          update_attrs = update_attrs.to_h.merge('custom_field_values' => existing.merge(custom_field_values_param.to_unsafe_h))
        end
        
        # Apply attributes to contact
        @contact.assign_attributes(update_attrs)

        # Validate only required fields that are visible in active layout
        layout_errors = validate_visible_required_fields('contacts', @contact)
        if layout_errors.any?
          Rails.logger.error "[ContactsController#update] Layout validation failed: #{layout_errors.join(', ')}"
          render json: {
            errors: layout_errors
          }, status: :unprocessable_entity
          return
        end

        @contact.save!(validate: false)  # Skip model validations, we validated above
        
        # Handle tags if provided
        handle_tags(@contact, tag_names) if tag_names

        render json: contact_json(@contact, detailed: true)
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
          
          # Auto-assign location from selector (if user selected a specific location)
          contact.location_id ||= Current.location_id if Current.location_id.present?
          
          # RBAC fallback: Location-tier users auto-assign to their first location if no selector
          if contact.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
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

      # POST /api/v1/contacts/check_duplicates
      # Plural duplicate lookup used by the New Contact form (matches the
      # leads/accounts shape). Returns an array of matches with matchedField
      # so the UI can hard-block email and soft-warn phone. Phone comparison
      # is digit-only so (303) 555-1212 matches 3035551212.
      def check_duplicates
        return unless authorize_action!('crm', 'read')

        email = params[:email].to_s.strip.downcase
        phone = params[:phone].to_s.gsub(/[^0-9]/, '')

        if email.blank? && phone.blank?
          render json: { duplicates: [] }
          return
        end

        # STRICT TENANT ISOLATION: only this company's contacts.
        scope = @company.contacts

        conditions = []
        values     = []
        if email.present?
          conditions << 'LOWER(email) = ?'
          values << email
        end
        if phone.present?
          conditions << "regexp_replace(COALESCE(phone, ''), '[^0-9]', '', 'g') = ?"
          values << phone
        end

        matches = scope.where(conditions.join(' OR '), *values).limit(5)

        same_type = matches.map { |c|
          c_phone = c.phone.to_s.gsub(/[^0-9]/, '')
          matched = if email.present? && c.email.to_s.downcase == email
                      'email'
                    elsif phone.present? && c_phone == phone
                      'phone'
                    else
                      'email'
                    end
          {
            id: c.id,
            firstName: c.first_name,
            lastName: c.last_name,
            email: c.email,
            phone: c.phone,
            matchedField: matched
          }
        }

        # Cross-entity awareness: surface leads/accounts that share this
        # email/phone (warnings only, never block). entityType lets the UI
        # label and link them correctly.
        cross = IdentityResolver.new(@company, email: email, phone: phone)
                                .all(exclude: nil)
                                .reject { |m| m.type == :contact }
                                .map { |m|
          {
            id: m.record.id,
            firstName: m.record.try(:first_name),
            lastName: m.record.try(:last_name),
            name: m.name.presence,
            email: m.record.try(:email),
            phone: m.record.try(:phone),
            matchedField: m.matched,
            entityType: m.type.to_s,
            converted: m.converted
          }
        }

        render json: { duplicates: same_type + cross }
      rescue => e
        Rails.logger.error "[ContactsController#check_duplicates] #{e.class}: #{e.message}"
        render json: { duplicates: [] }
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

        # Auto-assign owner to current user (quick_create has no account context)
        @contact.owner_id ||= current_user&.id
        
        # Auto-assign location from selector (if user selected a specific location)
        @contact.location_id ||= Current.location_id if Current.location_id.present?
        
        # RBAC fallback: Location-tier users auto-assign to their first location if no selector
        if @contact.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          @contact.location_id ||= location_ids.first if location_ids.any?
        end

        # Validate only required fields that are visible in active layout
        layout_errors = validate_visible_required_fields('contacts', @contact)
        if layout_errors.any?
          render json: { errors: layout_errors }, status: :unprocessable_entity
          return
        end

        if @contact.save(validate: false)  # Skip model validations, we validated above
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
        tag_names = tag_names.split(',') if tag_names.is_a?(String)
        
        tag_names.each do |tag_name|
          # Find or create tag within current company scope
          tag = @company.tags.find_or_create_by!(name: tag_name.strip) do |new_tag|
            new_tag.color = '#6B7280'
            new_tag.is_active = true
            new_tag.created_by = current_user&.id&.to_s || 'system'
          end
          
          # Create tag assignment using polymorphic association
          TagAssignment.find_or_create_by!(
            tag: tag,
            entity_type: 'Contact',
            entity_id: @contact.id
          ) do |assignment|
            assignment.company_id = @company.id
            assignment.assigned_by = current_user&.id&.to_s || 'system'
            assignment.assigned_at = Time.current
          end
        end
        
        # Reload tags association to get updated list
        @contact.reload
        render json: contact_json(@contact, detailed: true)
      end

      # DELETE /api/v1/contacts/:id/tags/:tag_name
      def remove_tag
        return unless authorize_action!('crm', 'update')
        
        # Find tag within company scope
        tag = @company.tags.find_by(name: params[:tag_name])
        
        if tag
          # Remove tag assignment using polymorphic association
          TagAssignment.where(
            tag: tag,
            entity_type: 'Contact',
            entity_id: @contact.id
          ).destroy_all
        end
        
        # Reload tags association to get updated list
        @contact.reload
        render json: contact_json(@contact, detailed: true)
      end

      # GET /api/v1/contacts/:id/tags
      def tags
        return unless authorize_action!('crm', 'read')
        
        # Get tags through the association
        tags = @contact.tags.map do |tag|
          {
            id: tag.id,
            name: tag.name,
            description: tag.description,
            color: tag.color,
            category: tag.category,
            type: tag.try(:tag_type),
            isSystem: tag.try(:is_system),
            isActive: tag.try(:is_active),
            usageCount: tag.usage_count,
            createdBy: tag.try(:created_by),
            createdAt: tag.created_at,
            updatedAt: tag.updated_at
          }.compact
        end
        
        render json: tags
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

      # GET /api/v1/contacts/:id/documents
      def documents
        return unless authorize_action!('crm', 'read')
        
        # Get ALL documents owned by this contact (regardless of related_to)
        documents = @contact.portal_documents.order(created_at: :desc)
        
        # Also include documents related to this contact's loans
        loan_related_docs = PortalDocument.where(
          related_to_type: 'Loan',
          related_to_id: @contact.loans.pluck(:id)
        ).where.not(owner_id: @contact.id) # Don't duplicate contact-owned docs
        
        all_documents = (documents + loan_related_docs.to_a).uniq.sort_by { |d| d.created_at }.reverse
        
        render json: {
          success: true,
          documents: all_documents.map { |doc| document_json(doc) }
        }
      rescue => e
        Rails.logger.error "Error in contacts#documents: #{e.message}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # POST /api/v1/contacts/:id/documents
      def upload_documents
        return unless authorize_action!('crm', 'update')
        
        uploaded_count = 0
        errors = []

        if params[:documents].present?
          params[:documents].each do |_index, doc_params|
            next unless doc_params[:file].present?

            begin
              document = @contact.portal_documents.new(
                document_name: doc_params[:name] || doc_params[:file].original_filename,
                category: doc_params[:category] || 'general',
                description: doc_params[:description],
                uploaded_by: current_user&.id&.to_s || 'admin',
                uploaded_at: Time.current
              )
              document.file.attach(doc_params[:file])
              
              if document.save
                uploaded_count += 1
              else
                errors << document.errors.full_messages.join(', ')
              end
            rescue => e
              Rails.logger.error "[ContactsController] Document upload failed: #{e.message}"
              errors << e.message
            end
          end
        end

        if errors.empty?
          render json: {
            success: true,
            message: "Successfully uploaded #{uploaded_count} document(s)",
            uploaded_count: uploaded_count
          }, status: :created
        else
          render json: {
            success: uploaded_count > 0,
            message: "Uploaded #{uploaded_count} document(s) with #{errors.length} error(s)",
            uploaded_count: uploaded_count,
            errors: errors
          }, status: :multi_status
        end
      rescue => e
        Rails.logger.error "Error in contacts#upload_documents: #{e.message}"
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
          :notes,
          :owner_id,
          :street,
          :city,
          :state,
          :zip,
          :country,
          # Delivery address
          :delivery_street,
          :delivery_city,
          :delivery_state,
          :delivery_zip,
          :delivery_country,
          # Inventory preferences
          :preferred_bedrooms,
          :preferred_bathrooms,
          :preferred_min_sqft,
          :preferred_max_sqft,
          :preferred_home_type,
          :preferred_vehicle_id,
          :budget_range
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
          :owner_id,
          :street,
          :city,
          :state,
          :zip,
          :country,
          # Delivery address
          :delivery_street,
          :delivery_city,
          :delivery_state,
          :delivery_zip,
          :delivery_country,
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

        # Owner filtering — mirrors AccountsController and the FE picker that
        # sends owner_id=<user_id> for a specific rep or 'null' for
        # unassigned. Previously ignored, which made the "Owner" dropdown on
        # the contacts list decorative (and made the new "default to my
        # contacts" behavior look broken).
        if params[:owner_id].present?
          contacts = params[:owner_id] == 'null' ? contacts.where(owner_id: nil) : contacts.where(owner_id: params[:owner_id])
        end

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
          ownerId: contact.owner_id,
          owner: contact.owner ? { id: contact.owner.id, name: contact.owner.name, email: contact.owner.email } : nil,
          optOutEmail: contact.opt_out_email,
          optOutEmailAt: contact.opt_out_email_at,
          optOutSms: contact.opt_out_sms,
          optOutSmsAt: contact.opt_out_sms_at,
          street: contact.street,
          city: contact.city,
          state: contact.state,
          zip: contact.zip,
          country: contact.country,
          deliveryStreet: contact.delivery_street,
          deliveryCity: contact.delivery_city,
          deliveryState: contact.delivery_state,
          deliveryZip: contact.delivery_zip,
          deliveryCountry: contact.delivery_country,
          accountName: contact.account&.name,
          # Inventory preferences
          preferredBedrooms:  contact.respond_to?(:preferred_bedrooms)   ? contact.preferred_bedrooms   : nil,
          preferredBathrooms: contact.respond_to?(:preferred_bathrooms)  ? contact.preferred_bathrooms  : nil,
          preferredMinSqft:   contact.respond_to?(:preferred_min_sqft)   ? contact.preferred_min_sqft   : nil,
          preferredMaxSqft:   contact.respond_to?(:preferred_max_sqft)   ? contact.preferred_max_sqft   : nil,
          preferredHomeType:  contact.respond_to?(:preferred_home_type)  ? contact.preferred_home_type  : nil,
          preferredVehicleId: contact.respond_to?(:preferred_vehicle_id) ? contact.preferred_vehicle_id : nil,
          budgetRange:        contact.respond_to?(:budget_range)         ? contact.budget_range         : nil,
          customFieldValues: contact.respond_to?(:custom_field_values) ? contact.custom_field_values : {},
          tags: contact.tags.map { |t| { id: t.id, name: t.name, color: t.color } },
          createdAt: contact.created_at,
          updatedAt: contact.updated_at
        }

        if detailed
          json.merge!(
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

      def document_json(document)
        {
          id: document.id,
          documentName: document.document_name,
          category: document.category,
          description: document.description,
          filename: document.filename,
          contentType: document.content_type,
          size: document.size,
          uploadedBy: document.uploaded_by,
          uploadedAt: document.uploaded_at,
          ownerType: document.owner_type,
          ownerId: document.owner_id,
          relatedToType: document.related_to_type,
          relatedToId: document.related_to_id,
          downloadUrl: "/api/v1/documents/#{document.id}/download",
          createdAt: document.created_at,
          updatedAt: document.updated_at
        }
      end
    end
  end
end
