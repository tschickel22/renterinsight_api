# frozen_string_literal: true

module Api
  module V1
    class CampaignUploadsController < ApplicationController
      before_action :set_company_scope

      # POST /api/v1/campaigns/:campaign_id/uploads
      # Uploads an image to S3 for inline use in email campaign step content (TipTap editor)
      def create
        return unless authorize_action!('campaigns', 'update')

        unless params[:file].present?
          return render json: { error: 'No file provided' }, status: :unprocessable_entity
        end

        file = params[:file]

        unless file.content_type.to_s.start_with?('image/')
          return render json: { error: 'Only image files are allowed' }, status: :unprocessable_entity
        end

        max_size = 5.megabytes
        if file.size > max_size
          return render json: { error: "File too large. Maximum size is #{max_size / 1.megabyte}MB" }, status: :unprocessable_entity
        end

        begin
          s3_service = S3UploadService.new
          folder = "campaigns/#{@company.id}/#{params[:campaign_id] || 'general'}"
          s3_result = s3_service.upload(file, folder: folder)

          render json: {
            url: s3_result[:url],
            s3_key: s3_result[:key],
            filename: file.original_filename,
            size: s3_result[:size],
            content_type: s3_result[:content_type]
          }
        rescue => e
          Rails.logger.error "Campaign upload failed: #{e.message}"
          render json: { error: "Upload failed: #{e.message}" }, status: :internal_server_error
        end
      end

      # DELETE /api/v1/campaigns/:campaign_id/uploads
      # Removes a previously uploaded image from S3
      def destroy
        return unless authorize_action!('campaigns', 'update')

        s3_key = params[:s3_key]
        unless s3_key.present?
          return render json: { error: 'No s3_key provided' }, status: :unprocessable_entity
        end

        unless s3_key.start_with?("campaigns/#{@company.id}/")
          return render json: { error: 'Access denied' }, status: :forbidden
        end

        begin
          s3_service = S3UploadService.new
          s3_service.delete(s3_key)
          render json: { message: 'File deleted' }
        rescue => e
          Rails.logger.error "Campaign upload delete failed: #{e.message}"
          render json: { error: "Delete failed: #{e.message}" }, status: :internal_server_error
        end
      end
    end
  end
end
