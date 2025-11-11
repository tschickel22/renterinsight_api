# frozen_string_literal: true

module Api
  module V1
    class BrochuresController < ApplicationController
      before_action :set_company_scope, except: [:templates, :public_view]
      before_action :set_brochure, only: [:show, :update, :destroy, :share]
      skip_before_action :authenticate, only: [:public_view]

      # GET /api/v1/brochures
      def index
        brochures = @company.brochures.active.includes(:company)
        
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
          'status'
        )
        
        @brochure = @company.brochures.new(safe_params)
        
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
          delivery_methods: []
        ).to_h
        
        # Default to email if no delivery methods specified
        send_params[:delivery_methods] ||= ['email']
        
        # Convert to symbols for service
        send_params_symbolized = send_params.deep_symbolize_keys
        
        begin
          result = BrochureSendingService.new(@brochure).send(**send_params_symbolized)
          
          if result[:sent].any?
            # Increment share count
            @brochure.increment_share_count!
            
            render json: {
              success: true,
              brochure: brochure_json(@brochure),
              sent_via: result[:sent].map { |r| { channel: r[:channel], to: r[:to] } },
              communications: result[:sent].map { |r| r[:communication]&.id }
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
        
        render json: {
          brochure: {
            id: @brochure.public_id,
            title: @brochure.title,
            description: @brochure.description,
            templateName: @brochure.template_name,
            templateData: @brochure.template_data,
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
        Rails.logger.info "✅ [BrochuresController] Stats endpoint called for company: #{@company&.name}"
        
        brochures = @company.brochures.active
        
        render json: {
          total: brochures.count,
          by_template: brochures.group(:template_name).count,
          total_views: brochures.sum(:view_count),
          total_shares: brochures.sum(:share_count),
          total_downloads: brochures.sum(:download_count),
          recent_count: brochures.where('created_at >= ?', 30.days.ago).count
        }
      rescue => e
        Rails.logger.error "🚫 [BrochuresController] Error in stats endpoint: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: 'Failed to load stats', message: e.message }, status: :internal_server_error
      end

      # GET /api/v1/brochures/templates
      def templates
        Rails.logger.info "✅ [BrochuresController] Templates endpoint called by user: #{current_user&.email || 'anonymous'}"
        
        # Return default templates
        # In production, these could be stored in database or loaded from config
        default_templates = [
          {
            id: 'modern',
            name: 'Modern Showcase',
            description: 'Clean, contemporary design with bold typography',
            theme: 'modern',
            preview_image: '/templates/modern-preview.jpg'
          },
          {
            id: 'luxury',
            name: 'Luxury Collection',
            description: 'Elegant design for premium properties',
            theme: 'luxury',
            preview_image: '/templates/luxury-preview.jpg'
          },
          {
            id: 'outdoor',
            name: 'Outdoor Adventure',
            description: 'Nature-inspired design for RV and outdoor properties',
            theme: 'outdoor',
            preview_image: '/templates/outdoor-preview.jpg'
          },
          {
            id: 'family',
            name: 'Family Friendly',
            description: 'Warm, welcoming design for family homes',
            theme: 'family',
            preview_image: '/templates/family-preview.jpg'
          }
        ]
        
        render json: { templates: default_templates }
      rescue => e
        Rails.logger.error "🚫 [BrochuresController] Error in templates endpoint: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: 'Failed to load templates', message: e.message }, status: :internal_server_error
      end

      private

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [BrochuresController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        unless current_user.company_id.present?
          Rails.logger.error "🚫 [BrochuresController] User #{current_user.id} has no company_id"
          render json: { error: 'No company assigned' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: current_user.company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [BrochuresController] Company #{current_user.company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [BrochuresController] Company scope set: #{@company.name} (ID: #{@company.id}) for user: #{current_user.email}"
      end

      def set_brochure
        @brochure = @company.brochures.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Brochure not found or access denied' }, status: :not_found
      end

      def brochure_json(brochure, detailed: false)
        base_url = request.base_url
        
        json = {
          id: brochure.id.to_s,
          title: brochure.title,
          description: brochure.description,
          publicId: brochure.public_id,
          publicUrl: brochure.public_url(base_url),
          templateName: brochure.template_name,
          templateData: brochure.template_data,
          vehicleIds: brochure.vehicle_ids,
          vehicleCount: brochure.vehicle_count,
          isPublic: brochure.is_public,
          status: brochure.status,
          viewCount: brochure.view_count,
          shareCount: brochure.share_count,
          downloadCount: brochure.download_count,
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
            base_url_for_images = Rails.env.production? ? "https://#{request.host}" : "http://#{request.host}:#{request.port}"
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
        base_url = Rails.env.production? ? "https://#{request.host}" : "http://#{request.host}:#{request.port}"
        
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
            city: vehicle.location_city,
            state: vehicle.location_state
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
    end
  end
end
