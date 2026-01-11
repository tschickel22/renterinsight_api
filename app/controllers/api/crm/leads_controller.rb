module Api
  module Crm
    class LeadsController < ApplicationController
      before_action :set_company_scope
      before_action :set_lead, only: [:show, :update, :destroy, :notes, :convert, :score]

      def index
        return unless authorize_action!('leads', 'read')
        
        # STRICT TENANT ISOLATION: Only show non-converted leads from current company
        # RBAC: Location-tier users only see their assigned locations
        # BUT: Users with :all scope see ALL locations (company-wide)
        leads = if current_user.uses_rbac?
          if current_user.effective_admin?  # Use RBAC-aware admin check
            @company.leads.where(is_converted: [false, nil])
          else
            # Check if user has company-wide scope (:all) for leads
            has_all_scope = permission_service.can?('leads', 'read', 'all')
            
            if has_all_scope
              # User has company-wide access - show all leads
              Rails.logger.info "[LeadsController#index] User has leads:read:all - showing all company leads"
              @company.leads.where(is_converted: [false, nil])
            else
              # User is location-restricted - filter by accessible locations
              location_ids = permission_service.accessible_location_ids
              Rails.logger.info "[LeadsController#index] User has location scope - accessible_location_ids: #{location_ids.inspect}"
              if location_ids.any?
                @company.leads.where(is_converted: [false, nil], location_id: location_ids)
              else
                @company.leads.where(is_converted: [false, nil])
              end
            end
          end
        else
          @company.leads.where(is_converted: [false, nil])
        end
        
        # Apply location selector filter (if user selected a specific location)
        leads = leads.for_current_location
        
        # Count total before pagination
        total_count = leads.count
        
        leads = leads.includes(:source).order(created_at: :desc)
        
        # Pagination
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i
        per_page = [per_page, 200].min # Max 200 per page
        
        leads = leads.offset((page - 1) * per_page).limit(per_page)
        
        render json: {
          leads: leads.map { |l| lead_json(l) },
          meta: {
            total: total_count,
            page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      def show
        return unless authorize_action!('leads', 'read')
        
        render json: lead_json(@lead)
      end

      def create
        return unless authorize_action!('leads', 'create')
        
        Rails.logger.info "[LeadsController#create] Received params: #{params.inspect}"
        Rails.logger.info "[LeadsController#create] Processed lead_params: #{lead_params.inspect}"
        
        # STRICT TENANT ISOLATION: Create lead within current company
        l = @company.leads.new(lead_params)
        
        # Auto-assign owner to current user if not specified
        l.owner_id ||= current_user&.id
        
        # Auto-assign location from selector (if user selected a specific location)
        l.location_id ||= Current.location_id if Current.location_id.present?
        
        # RBAC fallback: Location-tier users auto-assign to their first location if no selector
        if l.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          l.location_id ||= location_ids.first if location_ids.any?
        end
        
        if l.save
          Rails.logger.info "[LeadsController#create] Lead created successfully: ID=#{l.id}"
          render json: lead_json(l), status: :created
        else
          Rails.logger.error "[LeadsController#create] Validation failed: #{l.errors.full_messages.join(', ')}"
          render json: { 
            error: 'Validation failed', 
            details: l.errors.full_messages,
            params_received: lead_params 
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[LeadsController#create] Exception: #{e.class.name}: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        
        begin
          params_info = lead_params
        rescue
          params_info = 'Could not parse params'
        end
        
        render json: { 
          error: 'Internal server error', 
          message: e.message,
          params_received: params_info
        }, status: :internal_server_error
      end

      def update
        return unless authorize_action!('leads', 'update')
        
        Rails.logger.info "🔍 [LeadUpdate] BEFORE: lead_id=#{@lead.id}, owner_id=#{@lead.owner_id}, location_id=#{@lead.location_id}, is_converted=#{@lead.is_converted}"
        Rails.logger.info "🔍 [LeadUpdate] PARAMS: #{lead_params.inspect}"
        Rails.logger.info "🔍 [LeadUpdate] User: #{current_user.email}, RBAC locations: #{permission_service.accessible_location_ids.inspect}"
        
        @lead.update!(lead_params)
        
        Rails.logger.info "🔍 [LeadUpdate] AFTER: lead_id=#{@lead.id}, owner_id=#{@lead.owner_id}, location_id=#{@lead.location_id}, is_converted=#{@lead.is_converted}"
        Rails.logger.info "🔍 [LeadUpdate] Will user see this lead? RBAC=#{current_user.uses_rbac?}, Admin=#{current_user.effective_admin?}"
        
        render json: lead_json(@lead)
      end

      def destroy
        return unless authorize_action!('leads', 'delete')
        
        @lead.destroy!
        head :no_content
      end

      def notes
        return unless authorize_action!('leads', 'update')
        
        @lead.update!(notes: params[:notes].to_s)
        render json: lead_json(@lead)
      end

      def score
        return unless authorize_action!('leads', 'read')
        
        # Calculate lead score based on various factors
        score_value = calculate_lead_score(@lead)
        
        render json: {
          score: score_value,
          factors: [
            { name: 'Email Engagement', value: @lead.email.present? ? 20 : 0 },
            { name: 'Phone Available', value: @lead.phone.present? ? 15 : 0 },
            { name: 'Source Quality', value: @lead.source_id.present? ? 25 : 0 },
            { name: 'Recent Activity', value: 20 },
            { name: 'Profile Completeness', value: 20 }
          ]
        }
      end

      def convert
        return unless authorize_action!('leads', 'update')
        
        begin
          Rails.logger.info "Starting lead conversion for lead #{params[:id]}"
          
          # Check if already converted
          if @lead.is_converted
            render json: { error: 'Lead has already been converted' }, status: :unprocessable_entity
            return
          end
          
          # Create account with absolutely minimal fields
          account_name = params[:account_name].presence || "#{@lead.first_name} #{@lead.last_name}".strip
          account_name = "Converted Lead #{@lead.id}" if account_name.blank?
          
          Rails.logger.info "Creating account with name: #{account_name}"
          
          account = Account.new(
            name: account_name,
            company_id: @lead.company_id,
            status: 'active'
          )
          
          # Add optional fields if they won't cause validation errors
          account.email = @lead.email if @lead.email.present?
          account.phone = @lead.phone if @lead.phone.present?
          account.source_id = @lead.source_id if @lead.source_id.present?
          account.notes = @lead.notes if @lead.notes.present?
          
          # Auto-assign location from selector (if user selected a specific location)
          if Current.location_id.present?
            account.location_id = Current.location_id
          # RBAC fallback: Location-tier users auto-assign to their first location if no selector
          elsif current_user.uses_rbac? && !current_user.effective_admin?
            location_ids = permission_service.accessible_location_ids
            account.location_id = location_ids.first if location_ids.any?
          end
          
          # Try to set account_type if the field exists
          if account.respond_to?(:account_type=)
            account.account_type = 'converted_lead'
          end
          
          # Save the account
          if !account.save
            Rails.logger.error "Account validation failed: #{account.errors.full_messages.join(', ')}"
            render json: { error: "Failed to create account: #{account.errors.full_messages.join(', ')}" }, status: :unprocessable_entity
            return
          end
          
          Rails.logger.info "Account created with ID: #{account.id}"
          
          # Migrate lead activities to account activities
          begin
            if defined?(LeadActivity) && defined?(AccountActivity)
              Rails.logger.info "Starting migration of #{@lead.lead_activities.count} activities"
              
              @lead.lead_activities.each do |lead_activity|
                account_activity = AccountActivity.new(
                  account_id: account.id,
                  user_id: lead_activity.user_id,
                  assigned_to_id: lead_activity.assigned_to_id,
                  activity_type: lead_activity.activity_type,
                  subject: lead_activity.subject,
                  description: lead_activity.description,
                  status: lead_activity.status,
                  priority: lead_activity.priority,
                  due_date: lead_activity.due_date,
                  start_time: lead_activity.start_time,
                  end_time: lead_activity.end_time,
                  duration_minutes: lead_activity.duration_minutes,
                  completed_at: lead_activity.completed_at,
                  call_direction: lead_activity.call_direction,
                  call_outcome: lead_activity.call_outcome,
                  phone_number: lead_activity.phone_number,
                  meeting_location: lead_activity.meeting_location,
                  meeting_link: lead_activity.meeting_link,
                  meeting_attendees: lead_activity.meeting_attendees,
                  reminder_method: lead_activity.reminder_method,
                  reminder_time: lead_activity.reminder_time,
                  reminder_sent: lead_activity.reminder_sent,
                  estimated_hours: lead_activity.estimated_hours,
                  actual_hours: lead_activity.actual_hours,
                  outcome_notes: lead_activity.outcome_notes,
                  metadata: lead_activity.metadata,
                  created_at: lead_activity.created_at,
                  updated_at: lead_activity.updated_at
                )
                
                # For older "Activity" tab fields if they exist
                account_activity.outcome = lead_activity.outcome if lead_activity.respond_to?(:outcome)
                account_activity.duration = lead_activity.duration if lead_activity.respond_to?(:duration)
                account_activity.scheduled_date = lead_activity.scheduled_date if lead_activity.respond_to?(:scheduled_date)
                
                if account_activity.save
                  Rails.logger.info "Migrated activity #{lead_activity.id} to account activity #{account_activity.id}"
                else
                  Rails.logger.warn "Failed to migrate activity #{lead_activity.id}: #{account_activity.errors.full_messages.join(', ')}"
                end
              end
              
              Rails.logger.info "Activity migration completed"
            end
          rescue => e
            Rails.logger.error "Error during activity migration: #{e.message}"
            # Continue with conversion even if activity migration fails
          end
          
          # Mark lead as converted
          @lead.is_converted = true
          @lead.converted_at = Time.current
          @lead.converted_account_id = account.id
          
          if !@lead.save
            Rails.logger.error "Failed to update lead: #{@lead.errors.full_messages.join(', ')}"
            account.destroy # Rollback the account creation
            render json: { error: "Failed to mark lead as converted: #{@lead.errors.full_messages.join(', ')}" }, status: :unprocessable_entity
            return
          end
          
          Rails.logger.info "Lead marked as converted successfully"
          
          # Return simple response
          render json: {
            account: {
              id: account.id,
              name: account.name,
              email: account.email,
              phone: account.phone,
              status: account.status
            },
            contact: nil,
            deal: nil
          }, status: :ok
          
        rescue => e
          Rails.logger.error "Unexpected error during conversion: #{e.class.name}: #{e.message}"
          Rails.logger.error e.backtrace.first(10).join("\n")
          render json: { error: "Conversion failed: #{e.message}" }, status: :internal_server_error
        end
      end

      private

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [LeadsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [LeadsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [LeadsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [LeadsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end

      def set_lead
        # STRICT TENANT ISOLATION: Only access leads in same company
        # RBAC: Location-tier users only access their assigned locations
        # BUT: Users with :all scope access ALL leads (company-wide)
        @lead = if current_user.uses_rbac? && !current_user.effective_admin?
          # Check if user has company-wide scope (:all) for leads
          has_all_scope = permission_service.can?('leads', 'read', 'all')
          
          if has_all_scope
            # User has company-wide access
            Rails.logger.info "[LeadsController#set_lead] User has leads:read:all - accessing any company lead"
            @company.leads.find(params[:id])
          else
            # User is location-restricted
            location_ids = permission_service.accessible_location_ids
            Rails.logger.info "[LeadsController#set_lead] User has location scope - accessible_location_ids: #{location_ids.inspect}"
            if location_ids.any?
              @company.leads.where(location_id: location_ids).find(params[:id])
            else
              @company.leads.find(params[:id])
            end
          end
        else
          @company.leads.find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Lead not found or access denied' }, status: :not_found
        return
      end

      # Merge root + nested (:lead), accept camel & snake, normalize to snake.
      def lead_params
        # CRITICAL: company_id is NEVER updatable - it's set at creation from @company.id
        # Allowing company_id in params breaks tenant isolation!
        allowed = [:first_name, :last_name, :email, :phone, :notes, :source_id, :status, :owner_id,
                   :firstName, :lastName, :sourceId, :ownerId]

        root = params.permit(*allowed, lead: {})
        nested = params[:lead].is_a?(ActionController::Parameters) ? params.require(:lead).permit(*allowed) : {}

        raw = root.to_h.merge(nested.to_h) # nested wins if both present

        {
          first_name: raw['first_name'] || raw['firstName'],
          last_name:  raw['last_name']  || raw['lastName'],
          email:      raw['email'],
          phone:      raw['phone'],
          notes:      raw['notes'],
          status:     raw['status'],
          # company_id is EXCLUDED - never updatable!
          source_id:  (raw['source_id']  || raw['sourceId']).presence&.to_i,
          owner_id:   (raw['owner_id']   || raw['ownerId']).presence&.to_i
        }.compact
      end

      def calculate_lead_score(lead)
        score = 0
        score += 20 if lead.email.present?
        score += 15 if lead.phone.present?
        score += 25 if lead.source_id.present?
        score += 20 if lead.notes.present?
        score += 20 if lead.status.present? && lead.status != 'new'
        score
      end

      def lead_json(l)
        {
          id:        l.id,
          firstName: l.first_name,
          lastName:  l.last_name,
          email:     l.email,
          phone:     l.phone,
          notes:     l.notes,
          status:    l.status,
          sourceId:  l.source_id,
          source:    (l.source ? { id: l.source.id, name: l.source.name } : nil),
          ownerId:   l.owner_id,
          owner:     (l.owner ? { id: l.owner.id, name: l.owner.name, email: l.owner.email } : nil),
          isConverted: l.respond_to?(:is_converted) ? l.is_converted : false,
          convertedAt: l.respond_to?(:converted_at) ? l.converted_at : nil,
          convertedToAccountId: l.respond_to?(:converted_account_id) ? l.converted_account_id : nil,
          createdAt: l.created_at,
          updatedAt: l.updated_at
        }
      end
    end
  end
end
