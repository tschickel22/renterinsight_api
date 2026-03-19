# frozen_string_literal: true

module Api
  module V1
    class BrochuresController < ApplicationController
      before_action :set_company_scope, except: [:templates, :public_view]
      before_action :set_brochure, only: [:show, :update, :destroy, :share]
      before_action :authorize_read!, only: [:index, :show, :stats]
      before_action :authorize_create!, only: [:create]
      before_action :authorize_update!, only: [:update, :share, :bulk_share]
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
          # Pass current_user for user-level email connection waterfall
          result = BrochureSendingService.new(@brochure).send(**send_params_symbolized, user: current_user)
          
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

      # POST /api/v1/brochures/bulk_share
      # Bulk send a brochure to multiple leads
      def bulk_share
        brochure_id = params[:brochure_id]
        lead_ids = params[:lead_ids] || []
        custom_message = params[:custom_message]
        delivery_methods = params[:delivery_methods] || ['email']

        if brochure_id.blank? || lead_ids.empty?
          return render json: { error: 'brochure_id and lead_ids are required' }, status: :bad_request
        end

        brochure = @company.brochures.find_by(id: brochure_id)
        return render json: { error: 'Brochure not found' }, status: :not_found unless brochure

        leads = @company.leads.where(id: lead_ids, is_converted: [false, nil])
        if leads.empty?
          return render json: { error: 'No valid leads found' }, status: :not_found
        end

        sent_count = 0
        skipped_count = 0
        failed_count = 0
        errors = []

        leads.find_each do |lead|
          email = lead.email
          if email.blank?
            skipped_count += 1
            next
          end

          begin
            service = BrochureSendingService.new(brochure)
            result = service.send(
              delivery_methods: delivery_methods.map(&:to_s),
              to_email: email,
              to_phone: lead.phone,
              custom_message: custom_message,
              user: current_user
            )

            if result[:sent].any?
              sent_count += 1
              brochure.increment_share_count!

              # Create lead share activity
              begin
                create_lead_share_activity(lead.id, result, { 'to_email' => email, 'custom_message' => custom_message })
              rescue => e
                Rails.logger.warn "[BulkShare] Activity creation failed for lead #{lead.id}: #{e.message}"
              end
            else
              failed_count += 1
              errors << "Lead #{lead.id} (#{email}): #{result[:errors].first}"
            end
          rescue => e
            failed_count += 1
            errors << "Lead #{lead.id} (#{email}): #{e.message}"
            Rails.logger.error "[BulkShare] Error sending to lead #{lead.id}: #{e.message}"
          end
        end

        render json: {
          success: sent_count > 0,
          sent_count: sent_count,
          skipped_count: skipped_count,
          failed_count: failed_count,
          total: leads.count,
          errors: errors.first(10)  # Cap at 10 error messages
        }
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
        
        # Build calculator settings from loan_settings (public-safe subset only)
        loan_settings = company.loan_settings || {}
        calculator_settings = {
          enabled: loan_settings['calculator_enabled'] != false, # Default enabled
          defaultInterestRate: (loan_settings['default_interest_rate'] || 6.99).to_f,
          defaultLoanTermMonths: (loan_settings['max_loan_term'] || 240).to_i,
          minDownPaymentPercent: (loan_settings['min_down_payment_percent'] || 10).to_f,
          includeLotRent: loan_settings['calculator_include_lot_rent'] == true,
          defaultLotRentMonthly: (loan_settings['calculator_default_lot_rent'] || 0).to_f,
          includePropertyTax: loan_settings['calculator_include_property_tax'] == true,
          defaultPropertyTaxRate: (loan_settings['calculator_default_property_tax_rate'] || 1.0).to_f,
          includeInsurance: loan_settings['calculator_include_insurance'] == true,
          defaultInsuranceAnnual: (loan_settings['calculator_default_insurance_annual'] || 0).to_f,
          includeSetupFee: loan_settings['calculator_include_setup_fee'] == true,
          defaultSetupFee: (loan_settings['calculator_default_setup_fee'] || 0).to_f,
          loanTermOptions: (loan_settings['calculator_loan_term_options'] || [120, 180, 240, 300, 360]).map(&:to_i),
          disclaimerText: loan_settings['calculator_disclaimer_text'] || 'This calculator provides estimates only. Actual rates, terms, and payments may vary based on credit qualification and lender requirements. Contact us for personalized financing options.'
        }

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
            },
            calculatorSettings: calculator_settings
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
          next url if url.blank?
          url.start_with?('http') ? url : "#{base_url}#{url}"
        end.compact
        
        {
          id: vehicle.id.to_s,
          inventoryId: vehicle.inventory_id,
          listingType: vehicle.listing_type,
          year: vehicle.year,
          make: vehicle.make,
          model: vehicle.model,
          trim: vehicle.trim,
          displayName: vehicle.display_name,
          condition: vehicle.condition,
          color: vehicle.color,
          stockNumber: vehicle.stock_number,
          status: vehicle.status,
          statusLabel: vehicle.respond_to?(:status_label) ? vehicle.status_label : vehicle.status&.titleize,
          priceType: vehicle.respond_to?(:price_type) ? vehicle.price_type : 'sale',
          salePrice: vehicle.sale_price&.to_f,
          rentPrice: vehicle.rent_price&.to_f,
          msrp: vehicle.msrp&.to_f,
          specialDiscountEnabled: vehicle.respond_to?(:special_discount_enabled) ? vehicle.special_discount_enabled : false,
          discountedPrice: vehicle.respond_to?(:discounted_price) ? vehicle.discounted_price&.to_f : nil,
          description: vehicle.description,
          features: vehicle.features || [],
          images: full_image_urls,
          floorPlanImages: (vehicle.floor_plan_images || []).map { |url|
            next url if url.blank?
            url.start_with?('http') ? url : "#{base_url}#{url}"
          }.compact,
          videoUrl: vehicle.video_url,
          virtualTourUrl: vehicle.virtual_tour_url,
          # Location details
          location: {
            street: vehicle.address1,
            city: vehicle.location_city,
            state: vehicle.location_state,
            zip: vehicle.location_zip
          },
          locationType: vehicle.respond_to?(:location_type) ? vehicle.location_type : nil,
          communityName: vehicle.respond_to?(:community_name) ? vehicle.community_name : nil,
          communityKey: vehicle.respond_to?(:community_key) ? vehicle.community_key : nil,
          countyName: vehicle.respond_to?(:county_name) ? vehicle.county_name : nil,
          # Specs
          bedrooms: vehicle.bedrooms,
          bathrooms: vehicle.bathrooms,
          squareFootage: vehicle.square_feet,
          sleeps: vehicle.sleeps,
          length: vehicle.length,
          width: vehicle.width,
          length2: vehicle.length2,
          width2: vehicle.width2,
          length3: vehicle.length3,
          width3: vehicle.width3,
          sections: vehicle.sections,
          homeType: vehicle.home_type,
          vin: vehicle.vin,
          serialNumber: vehicle.serial_number,
          # Construction details
          exteriorMaterial: vehicle.respond_to?(:exterior_material) ? vehicle.exterior_material : nil,
          roofMaterial: vehicle.respond_to?(:roof_material) ? vehicle.roof_material : nil,
          flooringType: vehicle.respond_to?(:flooring_type) ? vehicle.flooring_type : nil,
          insulationType: vehicle.respond_to?(:insulation_type) ? vehicle.insulation_type : nil,
          ceilingType: vehicle.respond_to?(:ceiling_type) ? vehicle.ceiling_type : nil,
          wallType: vehicle.respond_to?(:wall_type) ? vehicle.wall_type : nil,
          # Inventory packages (add-ons)
          inventoryPackages: (vehicle.inventory_packages&.ordered || []).map { |pkg|
            {
              id: pkg.id,
              name: pkg.name,
              description: pkg.description,
              price: pkg.price&.to_f,
              includeInTotal: pkg.include_in_total,
              showPriceInMarketing: pkg.show_price_in_marketing,
              taxable: pkg.respond_to?(:taxable) ? (pkg.taxable || false) : false
            }
          },
          # Total home price including add-ons and discounts
          totalHomePrice: vehicle.total_home_price,
          # Total price before any discounts (msrp + packages)
          totalPriceBeforeDiscount: (vehicle.msrp || vehicle.sale_price || 0).to_f + (vehicle.inventory_packages&.where(include_in_total: true)&.sum(:price) || 0).to_f,
          # Amenities (boolean flags)
          amenities: {
            fireplace: vehicle.respond_to?(:fireplace) ? vehicle.fireplace : nil,
            garage: vehicle.respond_to?(:garage) ? vehicle.garage : nil,
            carport: vehicle.respond_to?(:carport) ? vehicle.carport : nil,
            deck: vehicle.respond_to?(:deck) ? vehicle.deck : nil,
            patio: vehicle.respond_to?(:patio) ? vehicle.patio : nil,
            centralAir: vehicle.respond_to?(:central_air) ? vehicle.central_air : nil,
            cathedralCeiling: vehicle.respond_to?(:cathedral_ceiling) ? vehicle.cathedral_ceiling : nil,
            ceilingFan: vehicle.respond_to?(:ceiling_fan) ? vehicle.ceiling_fan : nil,
            skylight: vehicle.respond_to?(:skylight) ? vehicle.skylight : nil,
            walkinCloset: vehicle.respond_to?(:walkin_closet) ? vehicle.walkin_closet : nil,
            laundryRoom: vehicle.respond_to?(:laundry_room) ? vehicle.laundry_room : nil,
            pantry: vehicle.respond_to?(:pantry) ? vehicle.pantry : nil,
            sunRoom: vehicle.respond_to?(:sun_room) ? vehicle.sun_room : nil,
            basement: vehicle.respond_to?(:basement) ? vehicle.basement : nil,
            storage: vehicle.respond_to?(:has_storage) ? vehicle.has_storage : nil,
            gardenTub: vehicle.respond_to?(:garden_tub) ? vehicle.garden_tub : nil,
            garbageDisposal: vehicle.respond_to?(:garbage_disposal) ? vehicle.garbage_disposal : nil,
            refrigerator: vehicle.respond_to?(:refrigerator) ? vehicle.refrigerator : nil,
            microwave: vehicle.respond_to?(:microwave) ? vehicle.microwave : nil,
            oven: vehicle.respond_to?(:oven) ? vehicle.oven : nil,
            dishwasher: vehicle.respond_to?(:dishwasher) ? vehicle.dishwasher : nil,
            clothesWasher: vehicle.respond_to?(:clothes_washer) ? vehicle.clothes_washer : nil,
            clothesDryer: vehicle.respond_to?(:clothes_dryer) ? vehicle.clothes_dryer : nil,
            gutters: vehicle.respond_to?(:gutters) ? vehicle.gutters : nil,
            shutters: vehicle.respond_to?(:shutters) ? vehicle.shutters : nil,
            thermopane: vehicle.respond_to?(:thermopane) ? vehicle.thermopane : nil
          }.compact,
          # Public custom fields
          customFields: public_custom_fields_for_vehicle(vehicle)
        }
      end

      # Cached public custom field definitions for brochure vehicles
      def public_custom_field_definitions
        @_public_cf_defs ||= begin
          company = @brochure&.company
          return [] unless company.present?
          company.custom_fields
                 .where(module: ['inventory', 'inventory_rv', 'inventory_mh'])
                 .where(is_active: true)
                 .where(visibility: ['public', 'both'])
                 .order(:section, :display_order, :created_at)
                 .to_a
        end
      end

      def public_custom_fields_for_vehicle(vehicle)
        fields = public_custom_field_definitions
        return [] if fields.empty?

        custom_values = vehicle.custom_field_values || {}

        fields.filter_map do |field|
          value = custom_values[field.field_key]
          next if value.nil? || (value.is_a?(String) && value.blank?)

          {
            key: field.field_key,
            label: field.label.presence || field.name,
            type: field.field_type,
            value: value,
            section: field.section,
            options: field.options
          }
        end
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
