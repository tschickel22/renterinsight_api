# frozen_string_literal: true

module Api
  module V1
    class AccountsController < ApplicationController
      before_action :set_company_scope
      before_action :set_account, only: %i[show update destroy convert_to_customer tags add_tags remove_tag activities deals contacts insights score communications_rollup]

      # GET /api/v1/accounts
      def index
        return unless authorize_action!('crm', 'read')
        
        # STRICT TENANT ISOLATION: Only show accounts from current company
        # RBAC: Location-tier users only see their assigned locations
        @accounts = if current_user.uses_rbac?
          if current_user.effective_admin?  # Use RBAC-aware admin check
            @company.accounts.where(is_deleted: [false, nil])
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              # Include accounts in assigned locations OR unassigned accounts (NULL location_id)
              @company.accounts.where(is_deleted: [false, nil])
                              .where("location_id IN (?) OR location_id IS NULL", location_ids)
            else
              @company.accounts.where(is_deleted: [false, nil])
            end
          end
        else
          @company.accounts.where(is_deleted: [false, nil])
        end
        
        # Apply location selector filter (if user selected a specific location)
        @accounts = @accounts.for_current_location
        
        @accounts = @accounts.includes(:tags, :source, :owner)
        
        # Apply filters (except search)
        @accounts = @accounts.where(account_type: params[:account_type]) if params[:account_type].present?
        @accounts = @accounts.where(rating: params[:rating]) if params[:rating].present?
        @accounts = @accounts.where(status: params[:status]) if params[:status].present?
        @accounts = @accounts.where(owner_id: params[:owner_id]) if params[:owner_id].present? && params[:owner_id] != 'null'
        @accounts = @accounts.where(owner_id: nil) if params[:owner_id] == 'null'
        
        # Count stats BEFORE search filter (stats tiles should show ALL accounts)
        all_accounts_count = @accounts.count
        status_counts = {
          customer: @accounts.where(account_type: 'customer').count,
          prospect: @accounts.where(account_type: 'prospect').count,
          partner: @accounts.where(account_type: 'partner').count,
          vendor: @accounts.where(account_type: 'vendor').count
        }
        
        # Apply search filter (searches name, email, phone, website)
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          @accounts = @accounts.where(
            "name ILIKE ? OR email ILIKE ? OR phone ILIKE ? OR website ILIKE ?",
            search_term, search_term, search_term, search_term
          )
        end
        
        # Count AFTER search filter (for pagination)
        filtered_count = @accounts.count
        
        # Paginate
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i
        per_page = [per_page, 200].min  # Cap at 200
        @accounts = @accounts.offset((page - 1) * per_page).limit(per_page)
        
        render json: {
          accounts: @accounts.as_json,
          meta: {
            total: filtered_count,  # For pagination (filtered results)
            page: page,
            per_page: per_page,
            total_pages: (filtered_count.to_f / per_page).ceil,
            stats: status_counts.merge(total: all_accounts_count)  # For tiles (unfiltered totals)
          }
        }
      end

      # GET /api/v1/accounts/:id
      def show
        return unless authorize_action!('crm', 'read')
        
        render json: @account.as_json
      end

      # POST /api/v1/accounts
      def create
        return unless authorize_action!('crm', 'create')
        
        # STRICT TENANT ISOLATION: Create account within current company
        @account = @company.accounts.new(account_params)
        
        # Auto-assign owner to current user if not explicitly set
        @account.owner_id ||= current_user&.id
        
        # Auto-assign location from selector (if user selected a specific location)
        @account.location_id ||= Current.location_id if Current.location_id.present?
        
        # RBAC fallback: Location-tier users auto-assign to their first location if no selector
        if @account.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          @account.location_id ||= location_ids.first if location_ids.any?
        end
        
        # Set default values for required fields
        @account.status ||= 'active'
        @account.account_type ||= 'prospect'
        
        # Clean up website field
        if @account.website.blank?
          @account.website = nil
        end
        
        # Validate only required fields that are visible in active layout
        layout_errors = validate_visible_required_fields('accounts', @account)
        if layout_errors.any?
          Rails.logger.error "[AccountsController#create] Layout validation failed: #{layout_errors.join(', ')}"
          render json: {
            errors: layout_errors
          }, status: :unprocessable_entity
          return
        end
        
        if @account.save(validate: false)  # Skip model validations, we validated above
          # Handle tags
          if params[:tags].present?
            tag_names = params[:tags].is_a?(Array) ? params[:tags] : params[:tags].split(',')
            tag_names.each do |tag_name|
              # Find or create tag within company scope
              tag = @company.tags.find_or_create_by!(name: tag_name.strip) do |new_tag|
                new_tag.color = '#6B7280'
                new_tag.is_active = true
                new_tag.created_by = current_user&.id&.to_s || 'system'
              end
              
              # Create tag assignment using polymorphic association
              TagAssignment.find_or_create_by!(
                tag: tag,
                entity_type: 'Account',
                entity_id: @account.id
              ) do |assignment|
                assignment.company_id = @company.id
                assignment.assigned_by = current_user&.id&.to_s || 'system'
                assignment.assigned_at = Time.current
              end
            end
          end
          
          @account.reload
          render json: @account.as_json, status: :created
        else
          render json: { errors: @account.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/accounts/:id
      def update
        return unless authorize_action!('crm', 'update')
        
        # Clean up website field if blank
        if params.key?(:website) && params[:website].blank?
          params[:website] = nil
        end
        
        # Handle custom_field_values merge (partial update pattern)
        update_attrs = account_params
        custom_field_values_param = params[:custom_field_values] || params[:account]&.dig(:custom_field_values)
        if custom_field_values_param.present?
          existing = @account.custom_field_values || {}
          update_attrs = update_attrs.to_h.merge('custom_field_values' => existing.merge(custom_field_values_param.to_unsafe_h))
        end
        
        # Apply attributes to account
        @account.assign_attributes(update_attrs)

        # Validate only required fields that are visible in active layout
        layout_errors = validate_visible_required_fields('accounts', @account)
        if layout_errors.any?
          Rails.logger.error "[AccountsController#update] Layout validation failed: #{layout_errors.join(', ')}"
          render json: {
            errors: layout_errors
          }, status: :unprocessable_entity
          return
        end

        @account.save!(validate: false)  # Skip model validations, we validated above
        
        # Handle tags if provided
        if params.key?(:tags)
          # Clear existing tags
          TagAssignment.where(entity_type: 'Account', entity_id: @account.id).destroy_all
          
          # Add new tags
          if params[:tags].present?
            tag_names = params[:tags].is_a?(Array) ? params[:tags] : params[:tags].split(',')
            tag_names.each do |tag_name|
              # Find or create tag within company scope
              tag = @company.tags.find_or_create_by!(name: tag_name.strip) do |new_tag|
                new_tag.color = '#6B7280'
                new_tag.is_active = true
                new_tag.created_by = current_user&.id&.to_s || 'system'
              end
              
              # Create tag assignment using polymorphic association
              TagAssignment.create!(
                tag: tag,
                entity_type: 'Account',
                entity_id: @account.id,
                company_id: @company.id,
                assigned_by: current_user&.id&.to_s || 'system',
                assigned_at: Time.current
              )
            end
          end
        end
        
        @account.reload
        render json: @account.as_json
      rescue => e
        Rails.logger.error "Error in accounts#update: #{e.message}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # DELETE /api/v1/accounts/:id
      def destroy
        return unless authorize_action!('crm', 'delete')
        
        @account.soft_delete!
        head :no_content
      end

      # POST /api/v1/accounts/:id/convert_to_customer
      def convert_to_customer
        return unless authorize_action!('crm', 'update')
        
        @account.convert_to_customer!
        render json: @account.as_json
      end

      # POST /api/v1/accounts/:id/tags
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
            entity_type: 'Account',
            entity_id: @account.id
          ) do |assignment|
            assignment.company_id = @company.id
            assignment.assigned_by = current_user&.id&.to_s || 'system'
            assignment.assigned_at = Time.current
          end
        end
        
        # Reload tags association to get updated list
        @account.reload
        render json: @account.as_json
      end

      # DELETE /api/v1/accounts/:id/tags/:tag_name
      def remove_tag
        return unless authorize_action!('crm', 'update')
        
        # Find tag within company scope
        tag = @company.tags.find_by(name: params[:tag_name])
        
        if tag
          # Remove tag assignment using polymorphic association
          TagAssignment.where(
            tag: tag,
            entity_type: 'Account',
            entity_id: @account.id
          ).destroy_all
        end
        
        # Reload tags association to get updated list
        @account.reload
        render json: @account.as_json
      end

      # GET /api/v1/accounts/:id/tags
      def tags
        return unless authorize_action!('crm', 'read')
        
        # Get tags through polymorphic association
        tag_ids = TagAssignment.where(entity_type: 'Account', entity_id: @account.id).pluck(:tag_id)
        tags = Tag.where(id: tag_ids).map do |tag|
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

      # GET /api/v1/accounts/:id/activities
      def activities
        return unless authorize_action!('crm', 'read')
        
        activities = @account.lead_activities.includes(:lead).order(created_at: :desc)
        
        # Simple pagination
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 25).to_i
        offset = (page - 1) * per_page
        
        total_count = activities.count
        activities = activities.limit(per_page).offset(offset)
        
        render json: {
          activities: activities.as_json(include: :lead),
          meta: {
            current_page: page,
            total_pages: (total_count.to_f / per_page).ceil,
            total_count: total_count
          }
        }
      end

      # GET /api/v1/accounts/:id/deals
      def deals
        return unless authorize_action!('crm', 'read')
        
        # Placeholder until Deal model exists
        render json: {
          deals: [],
          meta: {
            current_page: 1,
            total_pages: 0,
            total_count: 0
          }
        }
        
        # Original implementation for when Deal model exists:
        # deals = @account.deals.order(created_at: :desc)
        # 
        # # Simple pagination
        # page = (params[:page] || 1).to_i
        # per_page = (params[:per_page] || 25).to_i
        # offset = (page - 1) * per_page
        # 
        # total_count = deals.count
        # deals = deals.limit(per_page).offset(offset)
        # 
        # render json: {
        #   deals: deals.as_json,
        #   meta: {
        #     current_page: page,
        #     total_pages: (total_count.to_f / per_page).ceil,
        #     total_count: total_count
        #   }
        # }
      end

      # GET /api/v1/accounts/:id/contacts
      def contacts
        return unless authorize_action!('crm', 'read')
        
        contacts = @company.contacts.where(account_id: @account.id, is_deleted: [false, nil])
        
        # RBAC location filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            contacts = contacts.where("location_id IN (?) OR location_id IS NULL", location_ids)
          end
        end
        
        # Pagination (50 default, 200 max)
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i
        per_page = [per_page, 200].min
        
        total_count = contacts.count
        contacts = contacts.offset((page - 1) * per_page).limit(per_page)
        
        render json: {
          items: contacts.as_json(
            only: [:id, :first_name, :last_name, :email, :phone, :account_id, :created_at, :updated_at],
            methods: [:full_name]
          ),
          meta: {
            total: total_count,
            page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      # GET /api/v1/accounts/stats
      def stats
        return unless authorize_action!('crm', 'read')
        
        # STRICT TENANT ISOLATION: Only stats for current company
        base_accounts = @company.accounts.where(is_deleted: [false, nil])
        
        # Apply strict location filter - only accounts explicitly assigned to selected location
        if Current.location_filtered?
          base_accounts = base_accounts.where(location_id: Current.location_id)
        end
        
        render json: {
          total: base_accounts.count,
          by_type: base_accounts.group(:account_type).count,
          by_status: base_accounts.group(:status).count,
          by_rating: base_accounts.group(:rating).count,
          recent_conversions: base_accounts.where('converted_date >= ?', 30.days.ago).count,
          high_value: base_accounts.high_value.count
        }
      end

      # GET /api/v1/accounts/industries
      def industries
        return unless authorize_action!('crm', 'read')
        
        # STRICT TENANT ISOLATION: Only industries from current company
        industries = @company.accounts.where(is_deleted: [false, nil]).where.not(industry: [nil, '']).distinct.pluck(:industry)
        render json: industries
      end

      # GET /api/v1/accounts/export
      def export
        return unless authorize_action!('crm', 'export')
        
        # STRICT TENANT ISOLATION: Only export accounts from current company
        accounts = @company.accounts.where(is_deleted: [false, nil]).includes(:tags, :source, :owner)
        
        # Apply filters
        accounts = accounts.where(account_type: params[:type]) if params[:type].present?
        accounts = accounts.where(rating: params[:rating]) if params[:rating].present?
        accounts = accounts.where(status: params[:status]) if params[:status].present?
        accounts = accounts.search(params[:q]) if params[:q].present?
        
        # Generate CSV
        csv_data = CSV.generate(headers: true) do |csv|
          csv << ['Name', 'Email', 'Phone', 'Type', 'Status', 'Rating', 'Industry', 'Website', 'Owner', 'Source', 'Tags', 'Created Date']
          
          accounts.find_each do |account|
            csv << [
              account.name,
              account.email,
              account.phone,
              account.account_type,
              account.status,
              account.rating,
              account.industry,
              account.website,
              account.owner&.name,
              account.source&.name,
              account.tags.pluck(:name).join(', '),
              account.created_at.strftime('%Y-%m-%d')
            ]
          end
        end
        
        send_data csv_data, filename: "accounts_#{Date.current}.csv", type: 'text/csv'
      end

      # POST /api/v1/accounts/convert_lead
      def convert_lead
        return unless authorize_action!('crm', 'create')
        
        # STRICT TENANT ISOLATION: Only convert leads from current company
        lead = @company.leads.find(params[:lead_id])
        
        # Create account from lead
        account = @company.accounts.create!(
          name: lead.name || "#{lead.first_name} #{lead.last_name}",
          email: lead.email,
          phone: lead.phone,
          status: 'active',
          account_type: 'prospect',
          source_id: lead.source_id,
          owner_id: current_user&.id,
          billing_street: lead.street,
          billing_city: lead.city,
          billing_state: lead.state,
          billing_postal_code: lead.postal_code,
          billing_country: lead.country || 'USA'
        )
        
        # Auto-assign location from selector (if user selected a specific location)
        if account.location_id.nil? && Current.location_id.present?
          account.update(location_id: Current.location_id)
        # RBAC fallback: Location-tier users auto-assign to their first location if no selector
        elsif account.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          account.update(location_id: location_ids.first) if location_ids.any?
        end
        
        # Copy tags using proper company scoping
        lead.tags.each do |tag|
          TagAssignment.find_or_create_by!(
            tag: tag,
            entity_type: 'Account',
            entity_id: account.id
          ) do |assignment|
            assignment.company_id = @company.id
            assignment.assigned_by = current_user&.id&.to_s || 'system'
            assignment.assigned_at = Time.current
          end
        end
        
        # Update lead
        lead.update!(
          converted_account_id: account.id,
          conversion_date: Time.current,
          status: 'converted'
        )
        
        render json: account.as_json
      end

      # POST /api/v1/accounts/bulk_update
      def bulk_update
        return unless authorize_action!('crm', 'update')
        
        account_ids = params[:account_ids] || []
        update_attrs = params[:attributes] || {}
        
        # STRICT TENANT ISOLATION: Only update accounts from current company
        accounts = @company.accounts.where(id: account_ids)
        accounts.update_all(update_attrs.permit(:status, :rating, :account_type, :owner_id))
        
        render json: { updated_count: accounts.count }
      end

      # GET /api/v1/accounts/:id/insights
      def insights
        return unless authorize_action!('crm', 'read')
        
        # Get all communications for stats (don't limit yet)
        all_communications = Communication.where(communicable: @account)
        
        # Get recent communications for display
        recent_communications = all_communications.order(created_at: :desc).limit(10)
        
        # Get recent activities
        all_activities = @account.activities
        recent_activities = all_activities.order(created_at: :desc).limit(20)
        
        # Get communication stats
        total_communications = all_communications.count
        email_count = all_communications.where(channel: 'email').count
        sms_count = all_communications.where(channel: 'sms').count
        
        # Get recent notes
        notes = Note.where(entity_type: 'Account', entity_id: @account.id)
                   .order(created_at: :desc)
                   .limit(10)
        
        # Calculate engagement score
        engagement_score = calculate_engagement_score(@account, all_communications)
        
        render json: {
          account_id: @account.id,
          account_name: @account.name,
          engagement_score: engagement_score,
          communication_stats: {
            total: total_communications,
            email: email_count,
            sms: sms_count,
            last_contact: recent_communications.first&.created_at
          },
          recent_communications: recent_communications.map { |c| 
            {
              id: c.id,
              channel: c.channel,
              direction: c.direction,
              status: c.status,
              subject: c.subject,
              body: c.body&.truncate(100),
              created_at: c.created_at
            }
          },
          recent_activities: recent_activities.map { |a|
            {
              id: a.id,
              activity_type: a.activity_type,
              description: a.description || a.activity_type&.titleize,
              status: a.status,
              due_date: a.due_date,
              created_at: a.created_at
            }
          },
          recent_notes: notes.map { |n|
            {
              id: n.id,
              content: n.content&.truncate(200),
              created_at: n.created_at
            }
          },
          insights: generate_insights(@account, recent_communications, recent_activities)
        }
      end

      # GET /api/v1/accounts/:id/score
      def score
        return unless authorize_action!('crm', 'read')
        
        score_data = {
          account_id: @account.id,
          account_name: @account.name,
          activity_score: @account.activity_score || 0,
          engagement_level: determine_engagement_level(@account),
          scores: {
            communication: calculate_communication_score(@account),
            activity: calculate_activity_score(@account),
            recency: calculate_recency_score(@account),
            value: calculate_value_score(@account)
          },
          recommendations: generate_recommendations(@account)
        }
        
        render json: score_data
      end

      # GET /api/v1/accounts/:id/communications/rollup
      def communications_rollup
        return unless authorize_action!('crm', 'read')
        
        # Get all contacts for this account (tenant-isolated)
        contact_ids = @company.contacts.where(account_id: @account.id, is_deleted: [false, nil]).pluck(:id)
        
        # Get all leads that were CONVERTED TO this account (historical communications)
        # Note: Leads don't have account_id - they have converted_account_id after conversion
        # Note: Leads table doesn't have is_deleted column - uses status field instead
        lead_ids = @company.leads.where(converted_account_id: @account.id).pluck(:id)
        
        # Get all communications for contacts AND converted leads
        # Note: Communications table uses polymorphic association (communicable_type, communicable_id)
        # and 'channel' not 'communication_type'
        communications = Communication.where(
          "(communicable_type = 'Contact' AND communicable_id IN (?)) OR (communicable_type = 'Lead' AND communicable_id IN (?))",
          contact_ids.any? ? contact_ids : [0],
          lead_ids.any? ? lead_ids : [0]
        ).order(sent_at: :desc)
        
        # Calculate stats using correct column name 'channel'
        total_emails = communications.where(channel: 'email').count
        total_sms = communications.where(channel: 'sms').count
        
        # Calculate open rate from communication_events table
        opened_email_ids = CommunicationEvent.where(
          communication_id: communications.where(channel: 'email').pluck(:id),
          event_type: 'opened'
        ).distinct.pluck(:communication_id)
        opened_emails = opened_email_ids.count
        
        # Calculate open rate
        open_rate = total_emails > 0 ? ((opened_emails.to_f / total_emails) * 100).round(1) : 0
        
        # Paginate communications
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i
        per_page = [per_page, 200].min
        
        total_count = communications.count
        paginated_comms = communications.offset((page - 1) * per_page).limit(per_page)
        
        # Enrich communications with contact/lead name and event data
        enriched_comms = paginated_comms.map do |comm|
          # Handle both Contact and Lead communicable types
          if comm.communicable_type == 'Contact'
            entity = Contact.find_by(id: comm.communicable_id)
            entity_name = entity ? "#{entity.first_name} #{entity.last_name}" : 'Unknown Contact'
          else # Lead
            entity = Lead.find_by(id: comm.communicable_id)
            entity_name = entity ? "#{entity.first_name} #{entity.last_name}" : 'Unknown Lead'
          end
          
          # Get event timestamps from communication_events
          events = comm.communication_events
          opened_event = events.find_by(event_type: 'opened')
          clicked_event = events.find_by(event_type: 'clicked')
          
          {
            id: comm.id,
            type: comm.channel,  # 'email' or 'sms'
            status: comm.status,
            subject: comm.subject,
            content: comm.body,
            sent_at: comm.sent_at,
            delivered_at: comm.delivered_at,
            opened_at: opened_event&.occurred_at,
            clicked_at: clicked_event&.occurred_at,
            contact_name: entity_name,  # Works for both Contact and Lead
            contact_id: comm.communicable_id
          }
        end
        
        render json: {
          stats: {
            total_emails: total_emails,
            total_sms: total_sms,
            total_communications: total_count,
            open_rate: open_rate,
            contacts_count: contact_ids.count
          },
          communications: enriched_comms,
          meta: {
            total: total_count,
            page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      private

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [AccountsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [AccountsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [AccountsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [AccountsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end

      def set_account
        # STRICT TENANT ISOLATION: Only access accounts in same company
        # RBAC: Location-tier users only access their assigned locations
        @account = if current_user.uses_rbac? && !current_user.effective_admin?  # Use RBAC-aware admin check
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            # Include accounts in assigned locations OR unassigned accounts (NULL location_id)
            @company.accounts.where("location_id IN (?) OR location_id IS NULL", location_ids).find(params[:id])
          else
            @company.accounts.find(params[:id])
          end
        else
          @company.accounts.find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Account not found or access denied' }, status: :not_found
        return
      end

      def account_params
        # Support both wrapped { account: {...} } and unwrapped params
        raw = params[:account].present? ? params[:account].to_unsafe_h : params.to_unsafe_h
        
        # Build clean params with snake_case only
        clean = {}
        
        # Direct mappings (snake_case)
        %w[name email phone website industry status rating ownership description notes
           billing_street billing_city billing_state billing_postal_code billing_country
           shipping_street shipping_city shipping_state shipping_postal_code shipping_country
           parent_account_id owner_id].each do |key|
          clean[key] = raw[key] if raw.key?(key)
        end
        
        # Handle account_type (accept account_type, accountType, or type)
        clean['account_type'] = raw['account_type'] || raw['accountType'] || raw['type']
        
        # Handle source_id (accept source_id or sourceId)
        clean['source_id'] = raw['source_id'] || raw['sourceId']
        
        # Handle annual_revenue (accept annual_revenue or annualRevenue)
        clean['annual_revenue'] = raw['annual_revenue'] || raw['annualRevenue']
        
        # Handle employee_count (accept employee_count or employeeCount)
        clean['employee_count'] = raw['employee_count'] || raw['employeeCount']
        
        # Handle address object -> billing fields
        if raw['address'].is_a?(Hash)
          addr = raw['address']
          clean['billing_street'] ||= addr['street']
          clean['billing_city'] ||= addr['city']
          clean['billing_state'] ||= addr['state']
          clean['billing_postal_code'] ||= addr['zipCode'] || addr['zip_code']
          clean['billing_country'] ||= addr['country']
        end
        
        # Handle camelCase billing/shipping fields
        clean['billing_street'] ||= raw['billingStreet']
        clean['billing_city'] ||= raw['billingCity']
        clean['billing_state'] ||= raw['billingState']
        clean['billing_postal_code'] ||= raw['billingPostalCode']
        clean['billing_country'] ||= raw['billingCountry']
        clean['shipping_street'] ||= raw['shippingStreet']
        clean['shipping_city'] ||= raw['shippingCity']
        clean['shipping_state'] ||= raw['shippingState']
        clean['shipping_postal_code'] ||= raw['shippingPostalCode']
        clean['shipping_country'] ||= raw['shippingCountry']
        clean['parent_account_id'] ||= raw['parentAccountId']
        clean['owner_id'] ||= raw['ownerId']
        
        # Remove nil/blank values and return permitted params
        clean.compact.reject { |_, v| v.blank? }
      end

      # Helper methods for insights and scoring
      
      def calculate_engagement_score(account, communications)
        # Simple engagement score based on communication frequency and recency
        recent_comms = communications.where('created_at > ?', 30.days.ago).count
        recency_score = communications.any? ? [(30 - (Time.current - communications.first.created_at) / 1.day).to_i, 0].max : 0
        
        score = (recent_comms * 5) + recency_score
        [score, 100].min # Cap at 100
      end
      
      def generate_insights(account, communications, activities)
        insights = []
        
        # Communication insights
        if communications.empty?
          insights << {
            type: 'warning',
            title: 'No Communication History',
            message: 'No communications found with this account. Consider reaching out.'
          }
        elsif communications.where('created_at > ?', 30.days.ago).empty?
          insights << {
            type: 'warning',
            title: 'Inactive Account',
            message: 'No communication in the last 30 days. Account may need attention.'
          }
        else
          recent = communications.where('created_at > ?', 7.days.ago).count
          if recent > 5
            insights << {
              type: 'success',
              title: 'Highly Active',
              message: "#{recent} communications in the last 7 days. Great engagement!"
            }
          end
        end
        
        # Activity insights
        pending_activities = activities.where(status: 'pending').count
        if pending_activities > 0
          insights << {
            type: 'info',
            title: 'Pending Activities',
            message: "#{pending_activities} pending #{pending_activities == 1 ? 'activity' : 'activities'} require attention."
          }
        end
        
        # Overdue activities
        overdue = activities.where('due_date < ? AND status = ?', Time.current, 'pending').count
        if overdue > 0
          insights << {
            type: 'error',
            title: 'Overdue Activities',
            message: "#{overdue} #{overdue == 1 ? 'activity is' : 'activities are'} overdue."
          }
        end
        
        insights
      end
      
      def determine_engagement_level(account)
        score = account.activity_score || 0
        
        if score > 75
          'high'
        elsif score > 40
          'medium'
        else
          'low'
        end
      end
      
      def calculate_communication_score(account)
        comms = Communication.where(communicable: account)
        recent = comms.where('created_at > ?', 30.days.ago).count
        
        [recent * 10, 100].min
      end
      
      def calculate_activity_score(account)
        activities = account.activities.where('created_at > ?', 30.days.ago)
        completed = activities.where(status: 'completed').count
        
        [completed * 15, 100].min
      end
      
      def calculate_recency_score(account)
        last_comm = Communication.where(communicable: account).order(created_at: :desc).first
        return 0 unless last_comm
        
        days_ago = (Time.current - last_comm.created_at) / 1.day
        
        if days_ago < 7
          100
        elsif days_ago < 14
          75
        elsif days_ago < 30
          50
        else
          25
        end
      end
      
      def calculate_value_score(account)
        # Base value on account type and rating
        type_score = case account.account_type
        when 'customer' then 100
        when 'prospect' then 60
        else 30
        end
        
        rating_multiplier = case account.rating
        when 'hot' then 1.0
        when 'warm' then 0.8
        when 'cold' then 0.5
        else 0.6
        end
        
        (type_score * rating_multiplier).to_i
      end
      
      def generate_recommendations(account)
        recommendations = []
        
        # Check last communication
        last_comm = Communication.where(communicable: account).order(created_at: :desc).first
        if !last_comm || last_comm.created_at < 30.days.ago
          recommendations << {
            priority: 'high',
            action: 'reach_out',
            message: 'Consider reaching out to maintain relationship'
          }
        end
        
        # Check for pending activities
        pending = account.activities.where(status: 'pending').count
        if pending > 3
          recommendations << {
            priority: 'medium',
            action: 'complete_activities',
            message: "Complete #{pending} pending activities"
          }
        end
        
        # Check account type and rating
        if account.account_type == 'prospect' && account.rating == 'hot'
          recommendations << {
            priority: 'high',
            action: 'convert',
            message: 'Hot prospect - consider converting to customer'
          }
        end
        
        recommendations
      end
    end
  end
end
