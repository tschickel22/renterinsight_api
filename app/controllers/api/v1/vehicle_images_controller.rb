# frozen_string_literal: true

module Api
  module V1
    class VehicleImagesController < ApplicationController
      before_action :set_company

      # POST /api/v1/vehicles/:vehicle_id/images
      def create
        return render json: { error: 'No image provided' }, status: :bad_request unless params[:image]

        vehicle = @company.vehicles.find(params[:vehicle_id])
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
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Vehicle not found' }, status: :not_found
      rescue => e
        Rails.logger.error "Image upload failed: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: "Upload failed: #{e.message}" }, status: :internal_server_error
      end

      # DELETE /api/v1/vehicles/:vehicle_id/images
      def destroy
        vehicle = @company.vehicles.find(params[:vehicle_id])
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
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Vehicle not found' }, status: :not_found
      rescue => e
        Rails.logger.error "Image deletion failed: #{e.message}"
        render json: { error: "Deletion failed: #{e.message}" }, status: :internal_server_error
      end

      private

      def set_company
        # FIX: Better company validation
        @company = ::Company.find_by(id: current_user&.company_id) if current_user
        @company ||= ::Company.first
        
        unless @company
          render json: { error: 'No company found. Please contact support.' }, 
                 status: :unprocessable_entity
        end
      end
    end
  end
end
