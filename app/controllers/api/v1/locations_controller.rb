# frozen_string_literal: true

module Api
  module V1
    class LocationsController < ApplicationController
      # Authentication inherited from ApplicationController
      before_action :set_location, only: [:show, :update, :destroy, :restore, :users, :available_users, :metrics, :stats, :activities, :assign_user, :remove_user, :save_communication_settings, :clear_communication_settings]
      before_action :authorize_company_access!
      
      # RBAC permission checks
      before_action -> { authorize_rbac!('locations', 'read') }, only: [:index, :show, :users, :available_users, :metrics, :stats, :activities]
      before_action -> { authorize_rbac!('locations', 'create') }, only: [:create]
      before_action -> { authorize_rbac!('locations', 'update') }, only: [:update, :bulk_activate, :bulk_deactivate, :save_communication_settings, :clear_communication_settings]
      before_action -> { authorize_rbac!('locations', 'delete') }, only: [:destroy, :bulk_delete, :restore]
      before_action -> { authorize_rbac!('locations', 'assign') }, only: [:assign_user, :remove_user]

      # GET /api/v1/locations/accessible
      # Returns accessible locations for current user with selection requirement flag
      def accessible
        @locations = current_company.locations
                                    .where(is_deleted: false, active: true)
        
        # RBAC: Only location-tier users are restricted to assigned locations
        # Company-tier users can access all locations
        if current_user.uses_rbac? && !current_user.effective_admin?
          user_assignments = UserRoleAssignment.where(
            user_id: current_user.id,
            company_id: current_company.id
          ).active
          
          # Only restrict if user has location-tier role assignments
          if user_assignments.where(tier: 'location').any?
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              @locations = @locations.where(id: location_ids)
            else
              @locations = @locations.none
            end
          end
          # Company-tier users see all locations
        end
        
        @locations = @locations.order(:name)
        
        render json: {
          locations: @locations.select(:id, :name, :code, :city, :state).as_json(only: [:id, :name, :code, :city, :state]),
          requires_selection: @locations.count > 1
        }
      end
      
      # GET /api/v1/locations
      def index
        @locations = current_company.locations
                                    .where(is_deleted: false)
        
        # RBAC: Only location-tier users are restricted to assigned locations
        # Company-tier users can access all locations
        if current_user.uses_rbac? && !current_user.effective_admin?
          user_assignments = UserRoleAssignment.where(
            user_id: current_user.id,
            company_id: current_company.id
          ).active
          
          # Only restrict if user has location-tier role assignments
          if user_assignments.where(tier: 'location').any?
            location_ids = permission_service.accessible_location_ids
            @locations = @locations.where(id: location_ids) if location_ids.any?
          end
          # Company-tier users see all locations
        end
        
        @locations = @locations.order(:name)

        # Optional filtering
        @locations = @locations.where(active: true) if params[:active] == 'true'
        @locations = @locations.where(active: false) if params[:active] == 'false'

        render json: {
          locations: @locations.map { |location| location_json(location) },
          meta: {
            total: @locations.count,
            company_id: current_company.id
          }
        }
      end

      # GET /api/v1/locations/:id
      def show
        include_settings = params[:include_settings] == 'true'
        
        render json: {
          location: location_json(@location, include_settings: include_settings)
        }
      end

      # POST /api/v1/locations
      def create
        @location = current_company.locations.build(location_params)
        @location.created_by = current_user.id.to_s
        @location.updated_by = current_user.id.to_s

        if @location.save
          render json: {
            location: location_json(@location),
            message: 'Location created successfully'
          }, status: :created
        else
          render json: {
            errors: @location.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/locations/:id
      def update
        @location.updated_by = current_user.id.to_s

        if @location.update(location_params)
          render json: {
            location: location_json(@location),
            message: 'Location updated successfully'
          }
        else
          render json: {
            errors: @location.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/locations/:id
      def destroy
        if @location.soft_delete!
          render json: {
            message: 'Location deleted successfully'
          }
        else
          render json: {
            errors: ['Failed to delete location']
          }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/locations/:id/restore
      def restore
        if @location.restore!
          render json: {
            location: location_json(@location),
            message: 'Location restored successfully'
          }
        else
          render json: {
            errors: ['Failed to restore location']
          }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/locations/:id/users
      def users
        @users = @location.users.where(deleted_at: nil)
                         .includes(:user_locations)

        render json: {
          users: @users.map do |user|
            ul = user.user_locations.find_by(location_id: @location.id)
            {
              id: user.id,
              email: user.email,
              name: user.name,
              firstName: user.first_name,
              lastName: user.last_name,
              role: user.role,
              status: user.status,
              locationRole: ul&.location_role,
              active: ul&.active,
              assignedAt: ul&.created_at&.iso8601
            }
          end
        }
      end

      # GET /api/v1/locations/:id/available_users
      # Returns company users who can be assigned to this specific location
      # Excludes:
      #   - Users already assigned to this location
      #   - Users with company-wide legacy roles (platform_admin, super_admin, admin)
      #   - Users with company-tier RBAC roles (company_admin, company_manager, company_staff)
      #   These users already have access to ALL locations and don't need assignments
      def available_users
        assigned_user_ids = @location.user_locations.where(active: true).pluck(:user_id)
        
        # Get users with company-tier RBAC roles (they have all-location access)
        company_tier_roles = Role.where(key: ['company_admin', 'company_manager', 'company_staff'])
        company_tier_user_ids = if company_tier_roles.any?
          UserRoleAssignment.where(
            company_id: current_company.id,
            role_id: company_tier_roles.pluck(:id),
            tier: 'company'
          ).active.pluck(:user_id)
        else
          []
        end
        
        # Legacy roles that have company-wide access (don't need location assignments)
        company_wide_legacy_roles = %w[platform_admin super_admin admin]
        
        # Exclude: already assigned, company-wide legacy roles, and company-tier RBAC roles
        exclude_user_ids = (assigned_user_ids + company_tier_user_ids).uniq
        
        @users = current_company.users
                               .where(deleted_at: nil)
                               .where(status: 'active')
                               .where.not(id: exclude_user_ids)
                               .where.not(role: company_wide_legacy_roles)
                               .order(:name, :email)

        render json: {
          users: @users.map do |user|
            {
              id: user.id,
              email: user.email,
              name: user.name || "#{user.first_name} #{user.last_name}".strip,
              firstName: user.first_name,
              lastName: user.last_name,
              role: user.role,
              status: user.status
            }
          end,
          meta: {
            total: @users.count,
            locationId: @location.id,
            locationName: @location.name,
            excludedCompanyTier: company_tier_user_ids.length,
            excludedAssigned: assigned_user_ids.length
          }
        }
      end

      # POST /api/v1/locations/:id/assign_user
      def assign_user
        user = current_company.users.find(params[:user_id])
        location_role = params[:location_role] || 'location_staff'

        ul = @location.assign_user(user, role: location_role, assigned_by: current_user.id.to_s)

        # Log the assignment activity
        LocationActivity.log_user_assignment(
          location: @location,
          user: current_user,
          assigned_user: user,
          role: location_role
        )

        render json: {
          user_location: {
            user_id: ul.user_id,
            location_id: ul.location_id,
            location_role: ul.location_role,
            active: ul.active
          },
          message: 'User assigned to location successfully'
        }
      rescue ActiveRecord::RecordInvalid => e
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      # DELETE /api/v1/locations/:id/remove_user/:user_id
      def remove_user
        user = current_company.users.find(params[:user_id])
        @location.remove_user(user)

        render json: {
          message: 'User removed from location successfully'
        }
      end

      # GET /api/v1/locations/:id/metrics
      def metrics
        render json: {
          metrics: {
            active_vehicles: @location.active_vehicles_count,
            active_listings: @location.active_listings_count,
            open_leads: @location.open_leads_count,
            active_deals: @location.active_deals_count,
            total_users: @location.users.where(deleted_at: nil).count
          }
        }
      end

      # GET /api/v1/locations/:id/stats
      def stats
        render json: {
          stats: {
            active_vehicles: @location.active_vehicles_count,
            active_listings: @location.active_listings_count,
            assigned_users: @location.users.where(deleted_at: nil).count,
            open_leads: @location.open_leads_count
          }
        }
      end

      # GET /api/v1/locations/:id/activities
      def activities
        limit = [params[:limit]&.to_i || 20, 50].min
        activities = fetch_location_activities(@location, limit)
        
        render json: {
          activities: activities,
          meta: {
            location_id: @location.id,
            location_name: @location.name,
            total: activities.length
          }
        }
      end

      # POST /api/v1/locations/bulk_activate
      def bulk_activate
        location_ids = params[:location_ids] || []
        locations = current_company.locations.where(id: location_ids)
        
        # RBAC: Only location-tier users are restricted to assigned locations
        if current_user.uses_rbac? && !current_user.effective_admin?
          user_assignments = UserRoleAssignment.where(
            user_id: current_user.id,
            company_id: current_company.id
          ).active
          
          # Only restrict if user has location-tier role assignments
          if user_assignments.where(tier: 'location').any?
            accessible_ids = permission_service.accessible_location_ids
            locations = locations.where(id: accessible_ids)
          end
          # Company-tier users can bulk operate on all locations
        end

        updated_count = 0
        locations.each do |location|
          if location.update(active: true, updated_by: current_user.id.to_s)
            updated_count += 1
          end
        end

        render json: {
          message: "#{updated_count} location(s) activated successfully",
          updated_count: updated_count
        }
      end

      # POST /api/v1/locations/bulk_deactivate
      def bulk_deactivate
        location_ids = params[:location_ids] || []
        locations = current_company.locations.where(id: location_ids)
        
        # RBAC: Only location-tier users are restricted to assigned locations
        if current_user.uses_rbac? && !current_user.effective_admin?
          user_assignments = UserRoleAssignment.where(
            user_id: current_user.id,
            company_id: current_company.id
          ).active
          
          # Only restrict if user has location-tier role assignments
          if user_assignments.where(tier: 'location').any?
            accessible_ids = permission_service.accessible_location_ids
            locations = locations.where(id: accessible_ids)
          end
          # Company-tier users can bulk operate on all locations
        end

        updated_count = 0
        locations.each do |location|
          if location.update(active: false, updated_by: current_user.id.to_s)
            updated_count += 1
          end
        end

        render json: {
          message: "#{updated_count} location(s) deactivated successfully",
          updated_count: updated_count
        }
      end

      # POST /api/v1/locations/bulk_delete
      def bulk_delete
        location_ids = params[:location_ids] || []
        locations = current_company.locations.where(id: location_ids)
        
        # RBAC: Only location-tier users are restricted to assigned locations
        if current_user.uses_rbac? && !current_user.effective_admin?
          user_assignments = UserRoleAssignment.where(
            user_id: current_user.id,
            company_id: current_company.id
          ).active
          
          # Only restrict if user has location-tier role assignments
          if user_assignments.where(tier: 'location').any?
            accessible_ids = permission_service.accessible_location_ids
            locations = locations.where(id: accessible_ids)
          end
          # Company-tier users can bulk operate on all locations
        end

        deleted_count = 0
        locations.each do |location|
          if location.soft_delete!
            deleted_count += 1
          end
        end

        render json: {
          message: "#{deleted_count} location(s) deleted successfully",
          deleted_count: deleted_count
        }
      end

      # PATCH /api/v1/locations/:id/save_communication_settings
      # Save communication settings for THIS SPECIFIC LOCATION (with correct scope_id)
      def save_communication_settings
        settings = params[:communication_settings] || params[:settings] || {}
        
        # Convert ActionController::Parameters to hash if needed
        settings = settings.to_unsafe_h if settings.respond_to?(:to_unsafe_h)
        
        Rails.logger.info "[Location Settings] 💾 Saving communications settings for location #{@location.id} (#{@location.name})"
        Rails.logger.info "[Location Settings] Settings keys: #{settings.keys.join(', ')}"
        
        # CRITICAL: Save with THIS location's ID as scope_id
        Setting.set('Location', @location.id, 'communications', settings)
        
        # Verify it was saved correctly
        saved = Setting.get('Location', @location.id, 'communications')
        Rails.logger.info "[Location Settings] ✅ Verified saved for location #{@location.id}: #{saved.present?}"
        
        # Log the activity
        begin
          LocationActivity.log_settings_change(
            location: @location,
            user: current_user,
            category: 'communication',
            action: 'communication_changed',
            description: 'Communication settings updated'
          )
        rescue => e
          Rails.logger.warn "[Location Settings] Could not log activity: #{e.message}"
        end
        
        render json: { 
          success: true, 
          message: 'Communication settings updated successfully. Location will now use these settings for emails and SMS, falling back to company or platform settings if not specified.',
          settings: saved
        }
      rescue => e
        Rails.logger.error "[Location Settings] ❌ Error saving settings: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/locations/:id/clear_communication_settings
      # Clear all communication settings for this location and use parent defaults
      def clear_communication_settings
        # Delete the settings record entirely
        Setting.where(
          scope_type: 'Location',
          scope_id: @location.id,
          key: 'communications'
        ).destroy_all
        
        # Log the activity
        begin
          LocationActivity.log_settings_change(
            location: @location,
            user: current_user,
            category: 'communication',
            action: 'settings_cleared',
            description: 'Communication settings cleared - now using company/platform defaults'
          )
        rescue => e
          Rails.logger.warn "[Location Settings] Could not log activity: #{e.message}"
        end
        
        # Determine which parent settings will now be used
        company_settings = Setting.get('Company', current_company.id, 'communications')
        parent_source = company_settings.present? ? 'company' : 'platform'
        
        Rails.logger.info "[Location Settings] Cleared communications settings for location #{@location.id} (#{@location.name})"
        Rails.logger.info "[Location Settings] Now using #{parent_source} defaults"
        
        render json: { 
          success: true, 
          message: "Settings cleared successfully - now using #{parent_source} defaults",
          parent_source: parent_source
        }
      rescue => e
        Rails.logger.error "[Location Settings] Error clearing settings: #{e.message}"
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def set_location
        @location = current_company.locations.find(params[:id])
        
        # RBAC: Only location-tier users are restricted to assigned locations
        # Company-tier users (company_admin, company_manager, company_staff) can access all locations
        if current_user.uses_rbac? && !current_user.effective_admin?
          # Check if user has a location-tier role assignment
          user_assignments = UserRoleAssignment.where(
            user_id: current_user.id,
            company_id: current_company.id
          ).active
          
          # If user has any location-tier assignments, restrict to those locations
          if user_assignments.where(tier: 'location').any?
            location_ids = permission_service.accessible_location_ids
            unless location_ids.include?(@location.id)
              Rails.logger.warn "[RBAC] Location-tier user #{current_user.id} denied access to location #{@location.id}"
              render json: { error: 'Location not found or access denied' }, status: :not_found
              return
            end
          end
          # Company-tier users (company_staff, company_manager) fall through - they can access all locations
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Location not found' }, status: :not_found
      end

      def location_params
        params.require(:location).permit(
          :name,
          :code,
          :description,
          :phone,
          :email,
          :address_line1,
          :address_line2,
          :city,
          :state,
          :zip_code,
          :country,
          :timezone,
          :delivery_radius_miles,
          :active,
          allowed_form_states: [],
          business_hours: {},
          branding_settings: {},
          communication_settings: {},
          operational_settings: {},
          integration_settings: {}
        ).tap do |whitelisted|
          # Normalize branding_settings keys to snake_case for consistency
          if whitelisted[:branding_settings].present?
            whitelisted[:branding_settings] = normalize_branding_keys(whitelisted[:branding_settings])
            Rails.logger.info "🔧 [LocationsController] Normalized branding keys: #{whitelisted[:branding_settings].keys}"
          end
        end
      end

      # Normalize branding setting keys from camelCase to snake_case
      def normalize_branding_keys(settings)
        key_map = {
          'primaryColor' => 'primary_color',
          'secondaryColor' => 'secondary_color',
          'sideMenuColor' => 'side_menu_color',
          'fontFamily' => 'font_family',
          'logoUrl' => 'logo_url',
          'faviconUrl' => 'favicon_url',
          'portalName' => 'portal_name',
          'portalLogo' => 'portal_logo'
        }
        
        settings.transform_keys { |key| key_map[key.to_s] || key.to_s }
      end

      def location_json(location, include_settings: false)
        json = {
          id: location.id,
          company_id: location.company_id,
          name: location.name,
          code: location.code,
          description: location.description,
          phone: location.phone,
          email: location.email,
          address_line1: location.address_line1,
          address_line2: location.address_line2,
          city: location.city,
          state: location.state,
          zip_code: location.zip_code,
          country: location.country,
          full_address: location.full_address,
          address_summary: location.address_summary,
          timezone: location.timezone,
          delivery_radius_miles: location.delivery_radius_miles,
          business_hours: location.business_hours,
          active: location.active,
          allowed_form_states: location.respond_to?(:allowed_form_states) ? (location.allowed_form_states || []) : [],
          created_at: location.created_at,
          updated_at: location.updated_at,
          created_by: location.created_by,
          updated_by: location.updated_by
        }

        if include_settings
          # Check if company has operational settings
          company_has_operational = location.company.operational_settings.present? && 
                                   location.company.operational_settings.any?
          
          # Check if company has communication settings (meaningful, not just empty structure)
          company_has_communication = location.company.try(:has_communication_settings?) || false
          
          json.merge!({
            branding_settings: location.branding_settings,
            communication_settings: location.communication_settings,
            operational_settings: location.operational_settings,
            integration_settings: location.integration_settings,
            resolved_branding: location.resolved_branding_settings,
            resolved_communication: location.resolved_communication_settings,
            resolved_operational: location.resolved_operational_settings,
            resolved_integration: location.resolved_integration_settings,
            # Metadata for inheritance detection
            company_has_operational_settings: company_has_operational,
            company_has_communication_settings: company_has_communication
          })
        end

        json
      end

      def current_company
        @current_company ||= ::Company.find_by(id: current_company_id)
      end

      def authorize_company_access!
        unless current_company.present?
          render json: { error: 'No company associated with user' }, status: :forbidden
        end
      end

      # RBAC permission check with proper halting
      # Platform admins and super admins bypass all checks
      # If RBAC is disabled for company, allow all access
      def authorize_rbac!(resource, action, scope = 'all')
        # Platform admins bypass ALL permission checks
        return if current_user.platform_admin?
        return if current_user.super_admin?
        
        # If RBAC is disabled for this company, allow access
        return unless current_company&.use_rbac_system
        
        # Check RBAC permission
        unless current_user.has_permission?(resource, action, scope, current_company.id)
          Rails.logger.warn "[RBAC] Access denied: User #{current_user.id} lacks #{resource}:#{action}:#{scope}"
          render json: { 
            error: 'Access denied',
            details: "You don't have permission to #{action} #{resource}"
          }, status: :forbidden
        end
      end

      def fetch_location_activities(location, limit)
        activities = []

        # Recent location activities (settings changes, etc)
        begin
          recent_location_activities = location.location_activities
                                              .includes(:user)
                                              .order(occurred_at: :desc)
                                              .limit(limit / 4)
          recent_location_activities.each do |la|
            activities << {
              id: "location-activity-#{la.id}",
              type: activity_type_from_category(la.category),
              action: la.action,
              title: activity_title_from_category(la.category, la.action),
              description: la.description,
              timestamp: la.occurred_at.iso8601,
              time_ago: time_ago(la.occurred_at),
              entity_type: 'LocationActivity',
              entity_id: la.id,
              user_name: la.user&.name || la.user&.email
            }
          end
        rescue => e
          Rails.logger.warn "Failed to fetch location activities: #{e.message}"
        end

        # Recent vehicles at this location
        begin
          recent_vehicles = location.vehicles.where(is_deleted: false)
                                   .order(created_at: :desc)
                                   .limit(limit / 4)
          recent_vehicles.each do |vehicle|
            activities << {
              id: "vehicle-#{vehicle.id}",
              type: 'inventory',
              action: vehicle.created_at > 7.days.ago ? 'created' : 'updated',
              title: 'Inventory added',
              description: "#{vehicle.year} #{vehicle.make} #{vehicle.model} added to #{location.name}",
              timestamp: vehicle.created_at.iso8601,
              time_ago: time_ago(vehicle.created_at),
              entity_type: 'Vehicle',
              entity_id: vehicle.id
            }
          end
        rescue => e
          Rails.logger.warn "Failed to fetch vehicles for location activities: #{e.message}"
        end

        # Recent user assignments
        begin
          recent_assignments = location.user_locations
                                      .where(active: true)
                                      .order(created_at: :desc)
                                      .limit(limit / 4)
                                      .includes(:user)
          recent_assignments.each do |ul|
            next unless ul.user
            activities << {
              id: "user-assignment-#{ul.id}",
              type: 'user',
              action: 'assigned',
              title: 'User assigned',
              description: "#{ul.user.name || ul.user.email} assigned as #{ul.location_role&.humanize || 'staff'}",
              timestamp: ul.created_at.iso8601,
              time_ago: time_ago(ul.created_at),
              entity_type: 'User',
              entity_id: ul.user_id
            }
          end
        rescue => e
          Rails.logger.warn "Failed to fetch user assignments for location activities: #{e.message}"
        end

        # Recent leads at this location
        begin
          if defined?(Lead)
            recent_leads = location.leads.order(created_at: :desc).limit(limit / 4)
            recent_leads.each do |lead|
              activities << {
                id: "lead-#{lead.id}",
                type: 'lead',
                action: 'created',
                title: 'New lead',
                description: "#{lead.first_name} #{lead.last_name} - #{lead.status&.humanize || 'New'}",
                timestamp: lead.created_at.iso8601,
                time_ago: time_ago(lead.created_at),
                entity_type: 'Lead',
                entity_id: lead.id
              }
            end
          end
        rescue => e
          Rails.logger.warn "Failed to fetch leads for location activities: #{e.message}"
        end

        # Sort by timestamp descending and limit
        activities.sort_by { |a| a[:timestamp] }.reverse.take(limit)
      end

      def activity_type_from_category(category)
        case category
        when 'branding' then 'settings'
        when 'communication' then 'settings'
        when 'operational' then 'settings'
        when 'user_assignment' then 'user'
        else 'settings'
        end
      end

      def activity_title_from_category(category, action)
        case action
        when 'branding_changed' then 'Branding updated'
        when 'communication_changed' then 'Communication updated'
        when 'operational_changed' then 'Operational settings updated'
        when 'settings_cleared' then "#{category.humanize} cleared"
        when 'user_assigned' then 'User assigned'
        when 'user_removed' then 'User removed'
        else category.humanize
        end
      end

      def time_ago(time)
        seconds = Time.current - time
        
        case seconds
        when 0..59
          'just now'
        when 60..3599
          minutes = (seconds / 60).to_i
          "#{minutes} #{minutes == 1 ? 'minute' : 'minutes'} ago"
        when 3600..86399
          hours = (seconds / 3600).to_i
          "#{hours} #{hours == 1 ? 'hour' : 'hours'} ago"
        when 86400..2591999
          days = (seconds / 86400).to_i
          "#{days} #{days == 1 ? 'day' : 'days'} ago"
        else
          time.strftime('%B %d, %Y')
        end
      end
    end
  end
end
