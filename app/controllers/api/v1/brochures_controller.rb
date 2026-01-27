# frozen_string_literal: true

module Api
  module V1
    class BrochuresController < ApplicationController
      before_action :set_company_scope, except: [:templates, :public_view]
      before_action :set_brochure, only: [:show, :update, :destroy, :share]
      before_action :authorize_read!, only: [:index, :show, :stats]
      before_action :authorize_create!, only: [:create]
      before_action :authorize_update!, only: [:update, :share]
      before_action :authorize_delete!, only: [:destroy]
      skip_before_action :authenticate, only: [:public_view]

      # GET /api/v1/brochures
      def index
        # STRICT TENANT ISOLATION: Only return brochures from current user's company
        # RBAC: Location-tier users only see their assigned locations
        brochures = if current_user.uses_rbac?
          if current_user.effective_admin?
            @company.brochures
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              # Include brochures in assigned locations OR unassigned brochures (NULL location_id)
              @company.brochures.where("location_id IN (?) OR location_id IS NULL", location_ids)
            else
              @company.brochures.where(location_id: nil)
            end
          end
        else
          @company.brochures
        end
        
        # Apply strict location filter - only brochures explicitly assigned to selected location
        if Current.location_filtered?
          brochures = brochures.where(location_id: Current.location_id)
        end
        
        brochures = brochures.includes(:company, :location)
        
        # Status filter - active, inactive, or all
        if params[:status].present?
          case params[:status]
          when 'active'
            brochures = brochures.active
          when 'inactive'
            brochures = brochures.inactive
          end
          # If status is 'all' or any other value, show all records (no filter)
        else
          # Default to active only if no status parameter specified
          brochures = brochures.active
        end
        
        # Filters
        brochures = brochures.by_template(params[:template_name]) if params[:template_name].present?
        brochures = brochures.search(params[:search]) if params[:search].present?
        
        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order] || 'desc'
        brochures = brochures.order("#{sort_by} #{sort_order}")
        
        # Pagination
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 25).to_i, 100].min
        offset = (page - 1) * per_page
        
        total_count = brochures.count
        brochures = brochures.limit(per_page).offset(offset)
        
        render json: {
          brochures: brochures.map { |b| brochure_json(b) },
          meta: {
            current_page: page,
            total_pages: (total_count.to_f / per_page).ceil,
            total_count: total_count,
            per_page: per_page
          }
        }
      end

      # GET /api/v1/brochures/:id
      def show
        render json: { brochure: brochure_json(@brochure, detailed: true) }
      end

      # POST /api/v1/brochures
      def create
        brochure_params_hash = params.require(:brochure).to_unsafe_h
        
        # Transform camelCase to snake_case
        transformed_params = {}
        brochure_params_hash.each do |key, value|
          snake_key = key.to_s.underscore
          transformed_params[snake_key] = value
        end
        
        # Handle vehicle_ids array
        if transformed_params['vehicle_ids'].is_a?(Array)
          transformed_params['vehicle_ids'] = transformed_params['vehicle_ids'].map(&:to_s)
        end
        
        # Safe params with STRICT TENANT ISOLATION
        safe_params = transformed_params.slice(
          'title',
          'description',
          'template_name',
          'template_data',
          'vehicle_ids',
          'is_public',
          'status',
          'location_id'
        )
        
        @brochure = @company.brochures.new(safe_params)
        
        # Auto-assign location from Current.location_id (set by X-Location-ID header)
        @brochure.location_id ||= Current.location_id if Current.location_id.present?
        
        # RBAC fallback: Location-tier users auto-assign to their first location if no selector
        if @brochure.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          @brochure.location_id ||= location_ids.first if location_ids.any?
        end
        
        # Verify location belongs to company if specified
        if @brochure.location_id.present?
          location = @company.locations.find_by(id: @brochure.location_id)
          unless location
            render json: { error: 'Invalid location' }, status: :unprocessable_entity
            return
          end
          
          # RBAC: Verify user has access to this location (for non-admins)
          if current_user.uses_rbac? && !current_user.effective_admin?
            location_ids = permission_service.accessible_location_ids
            unless location_ids.include?(@brochure.location_id)
              render json: { error: 'You do not have access to this location' }, status: :forbidden
              return
            end
          end
        end
        
        if @brochure.save
          render json: { brochure: brochure_json(@brochure, detailed: true) }, status: :created
        else
          render json: { errors: @brochure.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error creating brochure: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH/PUT /api/v1/brochures/:id
      def update
        brochure_params_hash = params.require(:brochure).to_unsafe_h
        
        # Transform camelCase to snake_case
        transformed_params = {}
        brochure_params_hash.each do |key, value|
          snake_key = key.to_s.underscore
          transformed_params[snake_key] = value
        end
        
        # Handle vehicle_ids array
        if transformed_params['vehicle_ids'].is_a?(Array)
          transformed_params['vehicle_ids'] = transformed_params['vehicle_ids'].map(&:to_s)
        end
        
        # Safe params
        safe_params = transformed_params.slice(
          'title',
          'description',
          'template_name',
          'template_data',
          'vehicle_ids',
          'is_public',
          'status'
        )
        
        if @brochure.update(safe_params)
          render json: { brochure: brochure_json(@brochure, detailed: true) }
        else
          render json: { errors: @brochure.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error updating brochure: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/brochures/:id
      def destroy
        @brochure.soft_delete!
        head :no_content
      end

      # POST /api/v1/brochures/:id/share
      def share
        send_params = params.permit(
          :to_email,
          :to_phone,
          :custom_message,
          :from_email,
          :from_phone,
          :cc,
          :bcc,
          :contact_id,
          :lead_id,
          delivery_methods: []
        ).to_h
        
        # Extract contact_id and lead_id for activity tracking
        contact_id = send_params.delete(:contact_id)
        lead_id = send_params.delete(:lead_id)
        
        # Default to email if no delivery methods specified
        send_params[:delivery_methods] ||= ['email']
        
        # Convert to symbols for service
        send_params_symbolized = send_params.deep_symbolize_keys
        
        begin
          result = BrochureSendingService.new(@brochure).send(**send_params_symbolized)
          
          if result[:sent].any?
            # Increment share count
            @brochure.increment_share_count!
            
            # Create activity if contact_id or lead_id provided
            activity = nil
            if contact_id.present?
              activity = create_contact_share_activity(contact_id, result, send_params)
            elsif lead_id.present?
              activity = create_lead_share_activity(lead_id, result, send_params)
            end
            
            render json: {
              success: true,
              brochure: brochure_json(@brochure),
              sent_via: result[:sent].map { |r| { channel: r[:channel], to: r[:to] } },
              communications: result[:sent].map { |r| r[:communication]&.id },
              activity_id: activity&.id
            }
          else
            render json: {
              success: false,
              error: result[:errors].first || 'Failed to share brochure',
              errors: result[:errors],
              failed: result[:failed]
            }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { success: false, error: e.message }, status: :bad_request
        rescue => e
          Rails.logger.error "Error sharing brochure: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: { success: false, error: e.message }, status: :internal_server_error
        end
      end

      # GET /b/:public_id (public endpoint)
      def public_view
        @brochure = Brochure.public_brochures.find_by!(public_id: params[:public_id])
        @brochure.increment_view_count!
        
        # Get vehicles with full details
        vehicles = @brochure.vehicles.active.map { |v| vehicle_json_for_brochure(v) }
        
        # Get company branding
        company = @brochure.company
        branding = company.branding_settings || {}
        
        # Get template data and enhance with theme
        template_data = @brochure.template_data
        if template_data && template_data['theme'].is_a?(String)
          # Replace theme ID with full theme object
          template_data['theme'] = get_theme_data(template_data['theme'])
        end
        
        render json: {
          brochure: {
            id: @brochure.public_id,
            title: @brochure.title,
            description: @brochure.description,
            templateName: @brochure.template_name,
            templateData: template_data,
            vehicles: vehicles,
            viewCount: @brochure.view_count,
            createdAt: @brochure.created_at,
            company: {
              name: company.name,
              branding: branding
            }
          }
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Brochure not found or no longer available' }, status: :not_found
      end

      # GET /api/v1/brochures/stats
      def stats
        # RBAC: Location-tier users only see stats for their assigned locations
        all_brochures = if current_user.uses_rbac?
          if current_user.effective_admin?
            @company.brochures
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              @company.brochures.where("location_id IN (?) OR location_id IS NULL", location_ids)
            else
              @company.brochures.where(location_id: nil)
            end
          end
        else
          @company.brochures
        end
        
        # Apply strict location filter for stats
        if Current.location_filtered?
          all_brochures = all_brochures.where(location_id: Current.location_id)
        end
        
        active_brochures = all_brochures.active
        
        render json: {
          total: all_brochures.count,
          by_status: all_brochures.group(:status).count,
          by_template: active_brochures.group(:template_name).count,
          total_views: all_brochures.sum(:view_count),
          total_shares: all_brochures.sum(:share_count),
          total_downloads: all_brochures.sum(:download_count),
          recent_count: all_brochures.where('created_at >= ?', 30.days.ago).count
        }
      rescue => e
        Rails.logger.error "[BrochuresController] Error in stats endpoint: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: 'Failed to load stats', message: e.message }, status: :internal_server_error
      end

      # GET /api/v1/brochures/templates
      def templates
        # Return actual BrochureTemplate records from database
        templates = BrochureTemplate.active
        
        if templates.empty?
          # If no templates exist, create default ones
          create_default_templates
          templates = BrochureTemplate.active
        end
        
        # Format templates for frontend
        formatted_templates = templates.map do |template|
          {
            id: template.template_key,
            name: template.name,
            description: template.description,
            theme: template.theme,
            previewImage: template.preview_image,
            templateData: template.template_data
          }
        end
        
        render json: { templates: formatted_templates }
      rescue => e
        Rails.logger.error "[BrochuresController] Error in templates endpoint: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: 'Failed to load templates', message: e.message }, status: :internal_server_error
      end

      private

      # RBAC Authorization Methods
      # Brochures use 'listings' permission (Property Listings & Brochures)
      def authorize_read!
        return if skip_rbac?
        unless current_user.has_permission?('listings', 'read', 'all', @company&.id)
          Rails.logger.warn "[RBAC] User #{current_user.id} denied READ access to listings/brochures for company #{@company&.id}"
          render json: { error: 'Permission denied: You do not have permission to view brochures' }, status: :forbidden
        end
      end

      def authorize_create!
        return if skip_rbac?
        unless current_user.has_permission?('listings', 'create', 'all', @company&.id)
          Rails.logger.warn "[RBAC] User #{current_user.id} denied CREATE access to listings/brochures for company #{@company&.id}"
          render json: { error: 'Permission denied: You do not have permission to create brochures' }, status: :forbidden
        end
      end

      def authorize_update!
        return if skip_rbac?
        unless current_user.has_permission?('listings', 'update', 'all', @company&.id)
          Rails.logger.warn "[RBAC] User #{current_user.id} denied UPDATE access to listings/brochures for company #{@company&.id}"
          render json: { error: 'Permission denied: You do not have permission to update brochures' }, status: :forbidden
        end
      end

      def authorize_delete!
        return if skip_rbac?
        unless current_user.has_permission?('listings', 'delete', 'all', @company&.id)
          Rails.logger.warn "[RBAC] User #{current_user.id} denied DELETE access to listings/brochures for company #{@company&.id}"
          render json: { error: 'Permission denied: You do not have permission to delete brochures' }, status: :forbidden
        end
      end

      # Skip RBAC for platform admins or if company doesn't use RBAC
      def skip_rbac?
        return true if current_user.platform_admin?
        return true if current_user.super_admin?
        return true unless @company&.use_rbac_system
        false
      end

      def set_company_scope
        unless current_user
          Rails.logger.error "[BrochuresController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "[BrochuresController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "[BrochuresController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "[BrochuresController] Company scope set: #{@company.name} (ID: #{@company.id}) for user: #{current_user.email}"
      end

      def set_brochure
        @brochure = @company.brochures.find(params[:id])
        
        # RBAC: Verify user has access to this brochure's location
        if @brochure.location_id.present? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          unless location_ids.include?(@brochure.location_id)
            Rails.logger.warn "[RBAC] User #{current_user.id} denied access to brochure #{@brochure.id} at location #{@brochure.location_id}"
            render json: { error: 'Access denied - you do not have access to this location' }, status: :forbidden
            return
          end
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Brochure not found or access denied' }, status: :not_found
      end

      # Create activity record for brochure share to contact
      def create_contact_share_activity(contact_id, result, send_params)
        # Verify contact belongs to this company for tenant isolation
        contact = @company.contacts.find_by(id: contact_id)
        return nil unless contact
        
        # Build activity description
        channels = result[:sent].map { |r| r[:channel] }.uniq.join(' and ')
        recipients = result[:sent].map { |r| r[:to] }.uniq
        
        description_parts = []
        description_parts << "Shared brochure via #{channels}"
        description_parts << "Recipients: #{recipients.join(', ')}"
        description_parts << "Custom message: #{send_params[:custom_message]}" if send_params[:custom_message].present?
        description_parts << "\n#{@brochure.vehicle_count} properties included in collection"
        
        # Build brochure link
        base_url = request.base_url
        brochure_url = @brochure.public_url(base_url)
        brochure_link = @brochure.status == 'active' ? "\n\nView brochure: #{brochure_url}" : "\n\n(Brochure is no longer active)"
        
        description = description_parts.join("\n") + brochure_link
        
        # Create the activity
        activity = ContactActivity.create!(
          contact: contact,
          user: current_user,
          activity_type: 'note',
          subject: "Shared brochure: #{@brochure.title}",
          description: description,
          status: 'completed',
          priority: 'medium',
          completed_at: Time.current,
          metadata: {
            brochure_id: @brochure.id,
            brochure_public_id: @brochure.public_id,
            brochure_url: brochure_url,
            brochure_status: @brochure.status,
            vehicle_count: @brochure.vehicle_count,
            channels_used: result[:sent].map { |r| r[:channel] },
            communications: result[:sent].map { |r| r[:communication]&.id }.compact
          }
        )
        
        Rails.logger.info "Created activity #{activity.id} for brochure share to contact #{contact.id}"
        activity
      rescue => e
        Rails.logger.error "Failed to create share activity: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        nil
      end

      # Create activity record for brochure share to lead
      def create_lead_share_activity(lead_id, result, send_params)
        # Verify lead belongs to this company for tenant isolation
        lead = Lead.where(company_id: @company.id).find_by(id: lead_id)
        return nil unless lead
        
        # Build activity description
        channels = result[:sent].map { |r| r[:channel] }.uniq.join(' and ')
        recipients = result[:sent].map { |r| r[:to] }.uniq
        
        description_parts = []
        description_parts << "Shared brochure via #{channels}"
        description_parts << "Recipients: #{recipients.join(', ')}"
        description_parts << "Custom message: #{send_params[:custom_message]}" if send_params[:custom_message].present?
        description_parts << "\n#{@brochure.vehicle_count} properties included in collection"
        
        # Build brochure link
        base_url = request.base_url
        brochure_url = @brochure.public_url(base_url)
        brochure_link = @brochure.status == 'active' ? "\n\nView brochure: #{brochure_url}" : "\n\n(Brochure is no longer active)"
        
        description = description_parts.join("\n") + brochure_link
        
        # Create the activity
        activity = LeadActivity.create!(
          lead: lead,
          user: current_user,
          activity_type: 'note',
          subject: "Shared brochure: #{@brochure.title}",
          description: description,
          status: 'completed',
          priority: 'medium',
          completed_at: Time.current,
          metadata: {
            brochure_id: @brochure.id,
            brochure_public_id: @brochure.public_id,
            brochure_url: brochure_url,
            brochure_status: @brochure.status,
            vehicle_count: @brochure.vehicle_count,
            channels_used: result[:sent].map { |r| r[:channel] },
            communications: result[:sent].map { |r| r[:communication]&.id }.compact
          }
        )
        
        Rails.logger.info "Created activity #{activity.id} for brochure share to lead #{lead.id}"
        activity
      rescue => e
        Rails.logger.error "Failed to create lead share activity: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        nil
      end
      
      def brochure_json(brochure, detailed: false)
        base_url = request.base_url
        
        # Get template data and enhance with theme
        template_data = brochure.template_data
        if template_data && template_data['theme'].is_a?(String)
          # Replace theme ID with full theme object
          template_data['theme'] = get_theme_data(template_data['theme'])
        end
        
        json = {
          id: brochure.id.to_s,
          title: brochure.title,
          description: brochure.description,
          publicId: brochure.public_id,
          publicUrl: brochure.public_url(base_url),
          templateName: brochure.template_name,
          templateData: template_data,
          vehicleIds: brochure.vehicle_ids,
          vehicleCount: brochure.vehicle_count,
          isPublic: brochure.is_public,
          status: brochure.status,
          viewCount: brochure.view_count,
          shareCount: brochure.share_count,
          downloadCount: brochure.download_count,
          locationId: brochure.location_id&.to_s,
          locationName: brochure.location&.name,
          createdAt: brochure.created_at,
          updatedAt: brochure.updated_at
        }
        
        if detailed
          # Include full vehicle details for detailed view
          json[:vehicles] = brochure.vehicles.active.map { |v| vehicle_json_for_brochure(v) }
        else
          # For list view, include minimal vehicle data for thumbnails
          first_vehicle = brochure.vehicles.active.first
          if first_vehicle
            # Use HTTPS for all environments (local dev uses SSL certificates)
            base_url_for_images = request.ssl? ? "https://#{request.host}:#{request.port}" : "http://#{request.host}:#{request.port}"
            first_image = first_vehicle.images&.first
            full_image_url = first_image&.start_with?('http') ? first_image : "#{base_url_for_images}#{first_image}"
            
            json[:vehicles] = [{
              id: first_vehicle.id.to_s,
              images: [full_image_url]
            }]
          end
        end
        
        json
      end

      def vehicle_json_for_brochure(vehicle)
        # Use HTTPS for all environments (local dev uses SSL certificates)
        base_url = request.ssl? ? "https://#{request.host}:#{request.port}" : "http://#{request.host}:#{request.port}"
        
        full_image_urls = (vehicle.images || []).map do |url|
          url.start_with?('http') ? url : "#{base_url}#{url}"
        end
        
        {
          id: vehicle.id.to_s,
          inventoryId: vehicle.inventory_id,
          listingType: vehicle.listing_type,
          year: vehicle.year,
          make: vehicle.make,
          model: vehicle.model,
          trim: vehicle.trim,
          displayName: vehicle.display_name,
          salePrice: vehicle.sale_price&.to_f,
          rentPrice: vehicle.rent_price&.to_f,
          description: vehicle.description,
          features: vehicle.features || [],
          images: full_image_urls,
          location: {
            street: vehicle.address1,
            city: vehicle.location_city,
            state: vehicle.location_state,
            zip: vehicle.location_zip
          },
          bedrooms: vehicle.bedrooms,
          bathrooms: vehicle.bathrooms,
          squareFootage: vehicle.square_feet,
          sleeps: vehicle.sleeps,
          length: vehicle.length,
          vin: vehicle.vin,
          serialNumber: vehicle.serial_number
        }
      end
      
      # Theme definitions matching frontend
      def get_theme_data(theme_id)
        themes = {
          'modern' => {
            id: 'modern',
            name: 'Modern',
            description: 'Clean, contemporary design with bold typography',
            primaryColor: '#3b82f6',
            secondaryColor: '#64748b',
            accentColor: '#f59e0b',
            fontFamily: 'Inter',
            headerFont: 'Inter',
            bodyFont: 'Inter'
          },
          'luxury' => {
            id: 'luxury',
            name: 'Luxury',
            description: 'Elegant design for premium properties',
            primaryColor: '#1f2937',
            secondaryColor: '#6b7280',
            accentColor: '#d97706',
            fontFamily: 'Playfair Display',
            headerFont: 'Playfair Display',
            bodyFont: 'Inter'
          },
          'outdoor' => {
            id: 'outdoor',
            name: 'Outdoor Adventure',
            description: 'Nature-inspired design for RV and outdoor properties',
            primaryColor: '#059669',
            secondaryColor: '#374151',
            accentColor: '#dc2626',
            fontFamily: 'Montserrat',
            headerFont: 'Montserrat',
            bodyFont: 'Open Sans'
          },
          'family' => {
            id: 'family',
            name: 'Family Friendly',
            description: 'Warm, welcoming design for family homes',
            primaryColor: '#7c3aed',
            secondaryColor: '#6b7280',
            accentColor: '#f59e0b',
            fontFamily: 'Poppins',
            headerFont: 'Poppins',
            bodyFont: 'Inter'
          }
        }
        
        themes[theme_id] || themes['modern']
      end
      
      # Create default templates if none exist
      def create_default_templates
        templates_config = [
          {
            name: 'Modern Showcase',
            template_key: 'modern',
            description: 'Clean, contemporary design with bold typography',
            theme: 'modern',
            template_data: {
              theme: 'modern',
              blocks: [
                {
                  id: 'hero-1',
                  type: 'hero',
                  config: {
                    title: 'Modern Homes Collection',
                    subtitle: 'Explore our contemporary properties'
                  }
                },
                {
                  id: 'gallery-1',
                  type: 'gallery',
                  config: {
                    title: 'Featured Properties',
                    subtitle: 'Discover your next home',
                    maxItems: 15
                  }
                }
              ]
            },
            is_default: true
          },
          {
            name: 'Luxury Collection',
            template_key: 'luxury',
            description: 'Elegant design for premium properties',
            theme: 'luxury',
            template_data: {
              theme: 'luxury',
              blocks: [
                {
                  id: 'hero-1',
                  type: 'hero',
                  config: {
                    title: 'Luxury Estates',
                    subtitle: 'Experience sophisticated living'
                  }
                },
                {
                  id: 'gallery-1',
                  type: 'gallery',
                  config: {
                    title: 'Premium Homes',
                    subtitle: 'Curated collection of luxury properties',
                    maxItems: 15
                  }
                }
              ]
            },
            is_default: true
          },
          {
            name: 'Outdoor Explorer',
            template_key: 'outdoor',
            description: 'Nature-inspired design for RVs focused on camping and outdoor adventures. Earthy, adventurous feel.',
            theme: 'outdoor',
            template_data: {
              theme: 'outdoor',
              blocks: [
                {
                  id: 'hero-1',
                  type: 'hero',
                  config: {
                    title: 'Adventure Awaits',
                    subtitle: 'Your Gateway to the Great Outdoors'
                  }
                },
                {
                  id: 'gallery-1',
                  type: 'gallery',
                  config: {
                    title: 'Adventure-Ready RVs',
                    subtitle: 'Built for exploration and outdoor living',
                    maxItems: 15
                  }
                }
              ]
            },
            is_default: true
          },
          {
            name: 'Family Friendly',
            template_key: 'family',
            description: 'Warm, welcoming design for family homes',
            theme: 'family',
            template_data: {
              theme: 'family',
              blocks: [
                {
                  id: 'hero-1',
                  type: 'hero',
                  config: {
                    title: 'Family Homes',
                    subtitle: 'Perfect spaces for growing families'
                  }
                },
                {
                  id: 'gallery-1',
                  type: 'gallery',
                  config: {
                    title: 'Family-Friendly Properties',
                    subtitle: 'Comfort and space for everyone',
                    maxItems: 15
                  }
                }
              ]
            },
            is_default: true
          }
        ]
        
        templates_config.each do |config|
          BrochureTemplate.find_or_create_by!(template_key: config[:template_key]) do |template|
            template.name = config[:name]
            template.description = config[:description]
            template.theme = config[:theme]
            template.template_data = config[:template_data]
            template.is_default = config[:is_default]
            template.active = true
          end
        end
        
        Rails.logger.info "[BrochuresController] Created #{templates_config.size} default templates"
      end
    end
  end
end
