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

        # Validate file size (10MB limit)
        max_size = 10.megabytes
        if image_file.size > max_size
          return render json: {
            error: "File size exceeds maximum allowed (#{max_size / 1.megabyte}MB)"
          }, status: :unprocessable_entity
        end

        # Generate a unique S3 key
        ext = File.extname(image_file.original_filename).downcase
        filename = "#{SecureRandom.uuid}#{ext}"
        s3_key = "vehicles/#{@company.id}/#{vehicle.id}/#{filename}"

        # Upload to S3
        s3 = Aws::S3::Resource.new(
          region: ENV['AWS_REGION'] || 'us-west-2',
          access_key_id: ENV['AWS_ACCESS_KEY_ID'],
          secret_access_key: ENV['AWS_SECRET_ACCESS_KEY']
        )

        bucket_name = ENV['AWS_S3_BUCKET'] || 'renterinsight-website-assets-staging'
        obj = s3.bucket(bucket_name).object(s3_key)
        obj.put(
          body: image_file.read,
          content_type: image_file.content_type,
          acl: 'public-read'
        )

        full_url = obj.public_url

        # Add to vehicle's images array
        current_images = vehicle.images || []
        current_images << full_url
        vehicle.update!(images: current_images)

        render json: {
          success: true,
          url: full_url,
          relative_url: full_url,  # Keep same field name for frontend compatibility
          filename: filename
        }, status: :created

      rescue Aws::S3::Errors::ServiceError => e
        Rails.logger.error "[VehicleImages] S3 upload failed: #{e.message}"
        render json: { error: "Image upload failed: #{e.message}" }, status: :internal_server_error
      rescue => e
        Rails.logger.error "[VehicleImages] Upload failed: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        render json: { error: "Upload failed: #{e.message}" }, status: :internal_server_error
      end

      # DELETE /api/v1/vehicles/:vehicle_id/images
      def destroy
        vehicle = find_vehicle_with_rbac(params[:vehicle_id])
        return unless vehicle

        image_url = params[:url]
        return render json: { error: 'No URL provided' }, status: :bad_request unless image_url

        # Remove from BOTH images and floor_plan_images, matching whether entries
        # are plain URL strings or { "url", "alt" } objects (catalog imports store
        # objects; FE-saved arrays store strings).
        url_of = ->(img) { img.is_a?(Hash) ? (img['url'] || img[:url]) : img }
        without = ->(arr) { Array(arr).reject { |img| url_of.call(img) == image_url } }
        vehicle.update!(
          images: without.call(vehicle.images),
          floor_plan_images: without.call(vehicle.floor_plan_images)
        )

        # Delete from S3 if it's an S3 URL for our bucket
        if image_url.include?('amazonaws.com') || image_url.include?('renterinsight')
          begin
            s3_key = URI.parse(image_url).path.sub(/^\//, '')
            s3 = Aws::S3::Resource.new(
              region: ENV['AWS_REGION'] || 'us-west-2',
              access_key_id: ENV['AWS_ACCESS_KEY_ID'],
              secret_access_key: ENV['AWS_SECRET_ACCESS_KEY']
            )
            bucket_name = ENV['AWS_S3_BUCKET'] || 'renterinsight-website-assets-staging'
            s3.bucket(bucket_name).object(s3_key).delete
          rescue => e
            Rails.logger.warn "[VehicleImages] S3 delete failed (non-fatal): #{e.message}"
          end
        end

        render json: { success: true }
      rescue => e
        Rails.logger.error "[VehicleImages] Deletion failed: #{e.message}"
        render json: { error: "Deletion failed: #{e.message}" }, status: :internal_server_error
      end

      private

      def set_company
        unless current_user
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end

        company_id = current_company_id
        unless company_id.present?
          render json: { error: 'No company context' }, status: :forbidden
          return
        end

        @company = ::Company.find_by(id: company_id)
        unless @company
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
      end

      def find_vehicle_with_rbac(vehicle_id)
        vehicle = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
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
