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

        # Generate a unique filename
        ext = File.extname(image_file.original_filename)
        filename = "#{SecureRandom.uuid}#{ext}"
        
        # Create uploads directory if it doesn't exist
        uploads_dir = Rails.root.join('public', 'uploads', 'vehicles', vehicle.id.to_s)
        FileUtils.mkdir_p(uploads_dir)

        # Save the file
        filepath = uploads_dir.join(filename)
        File.open(filepath, 'wb') do |file|
          file.write(image_file.read)
        end

        # Generate the URL path (relative to public)
        image_url = "/uploads/vehicles/#{vehicle.id}/#{filename}"
        
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
        @company = ::Company.find_by(id: current_user.company_id)
        @company ||= ::Company.first
        
        unless @company
          render json: { error: 'Company not found' }, status: :not_found
        end
      end
    end
  end
end
