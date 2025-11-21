# frozen_string_literal: true

module Api
  module V1
    class VehicleImagesController < ApplicationController
      include RbacAuthorization
      rbac_resource :inventory,
        read_actions: [],
        create_actions: [:create],
        update_actions: [],
        delete_actions: [:destroy]

      before_action :set_company

      # POST /api/v1/vehicles/:vehicle_id/images
      def create
        return render json: { error: 'No image provided' }, status: :bad_request unless params[:image]

        vehicle = find_vehicle_with_rbac(params[:vehicle_id])
        return unless vehicle
        
        image_file = params[:image]

        # FIX: Validate file size (10MB limit)
        max_size = 10.megabytes
        if image_file.size > max_size
          return render json: { 
            error: "File size exceeds maximum allowed (#{max_size / 1.megabyte}MB)" 
          }, status: :unprocessable_entity
        end

        # Generate a unique filename
        ext = File.extname(image_file.original_filename)
        filename = "#{SecureRandom.uuid}#{ext}"
        
        # FIX: Use company-based path instead of vehicle-based to avoid deep nesting
        uploads_dir = Rails.root.join('public', 'uploads', @company.id.to_s, 'vehicles')
        
        # FIX: Better error handling for directory creation
        begin
          FileUtils.mkdir_p(uploads_dir)
        rescue Errno::EACCES, Errno::EPERM => e
          Rails.logger.error "Permission denied creating directory: #{e.message}"
          return render json: { 
            error: "Server configuration error: Unable to create upload directory. Please contact support." 
          }, status: :internal_server_error
        rescue => e
          Rails.logger.error "Failed to create directory: #{e.message}"
          return render json: { 
            error: "Failed to create upload directory" 
          }, status: :internal_server_error
        end

        # Save the file with error handling
        filepath = uploads_dir.join(filename)
        begin
          File.open(filepath, 'wb') do |file|
            file.write(image_file.read)
          end
        rescue Errno::EACCES, Errno::EPERM => e
          Rails.logger.error "Permission denied writing file: #{e.message}"
          return render json: { 
            error: "Server configuration error: Unable to save file. Please contact support." 
          }, status: :internal_server_error
        rescue => e
          Rails.logger.error "Failed to write file: #{e.message}"
          return render json: { 
            error: "Failed to save file to storage" 
          }, status: :internal_server_error
        end

        # Generate the URL path (relative to public)
        image_url = "/uploads/#{@company.id}/vehicles/#{filename}"
        
        # Return full URL for cross-origin access
        base_url = Rails.env.production? ? "https://#{request.host}" : "http://#{request.host}:#{request.port}"
        full_url = "#{base_url}#{image_url}"

        # Add to vehicle's images array
        current_images = vehicle.images || []
        current_images << image_url
        vehicle.update(images: current_images)

        render json: { 
          success: true,
          url: full_url,  # Return full URL for immediate display
          relative_url: image_url,  # Also return relative URL for database
          filename: filename
        }, status: :created
      rescue => e
        Rails.logger.error "Image upload failed: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: "Upload failed: #{e.message}" }, status: :internal_server_error
      end

      # DELETE /api/v1/vehicles/:vehicle_id/images
      def destroy
        vehicle = find_vehicle_with_rbac(params[:vehicle_id])
        return unless vehicle
        
        image_url = params[:url]

        return render json: { error: 'No URL provided' }, status: :bad_request unless image_url

        # Remove from vehicle's images array
        current_images = vehicle.images || []
        current_images.delete(image_url)
        vehicle.update(images: current_images)

        # Delete the actual file if it exists locally
        if image_url.start_with?('/uploads/')
          filepath = Rails.root.join('public', image_url.sub(/^\//, ''))
          File.delete(filepath) if File.exist?(filepath)
        end

        render json: { success: true }
      rescue => e
        Rails.logger.error "Image deletion failed: #{e.message}"
        render json: { error: "Deletion failed: #{e.message}" }, status: :internal_server_error
      end

      private

      def set_company
        # STRICT TENANT ISOLATION: Only load company from authenticated user
        unless current_user
          Rails.logger.error "🚫 [VehicleImagesController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [VehicleImagesController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [VehicleImagesController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [VehicleImagesController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end
      
      def find_vehicle_with_rbac(vehicle_id)
        # STRICT TENANT ISOLATION: Only find vehicles within company
        # RBAC: Location-tier users only access vehicles in their assigned locations
        vehicle = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            # Include vehicles in assigned locations OR unassigned vehicles (NULL location_id)
            @company.vehicles.active.where("location_id IN (?) OR location_id IS NULL", location_ids).find(vehicle_id)
          else
            @company.vehicles.active.find(vehicle_id)
          end
        else
          @company.vehicles.active.find(vehicle_id)
        end
        
        vehicle
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Vehicle not found or access denied' }, status: :not_found
        nil
      end
    end
  end
end
