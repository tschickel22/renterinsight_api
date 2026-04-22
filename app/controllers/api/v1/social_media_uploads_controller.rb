# frozen_string_literal: true

module Api
  module V1
    # S3 upload endpoint for social media creatives (posts, ads). Reuses the
    # same S3UploadService + env-var setup as CustomFieldUploadsController so
    # bucket/region/credential handling stays consistent across the app.
    class SocialMediaUploadsController < ApplicationController
      before_action :set_company_scope

      ALLOWED_CONTENT_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze
      MAX_SIZE = 10.megabytes

      # POST /api/v1/social-media/upload
      def create
        return unless authorize_action!('social_posts', 'create')

        file = params[:file]
        return render json: { error: 'No file provided' }, status: :bad_request unless file.present?

        unless ALLOWED_CONTENT_TYPES.include?(file.content_type)
          return render json: { error: 'Only image files (JPEG, PNG, GIF, WebP) are allowed' }, status: :unprocessable_entity
        end

        if file.size > MAX_SIZE
          return render json: { error: 'File must be under 10MB' }, status: :unprocessable_entity
        end

        begin
          result = S3UploadService.new.upload(file, folder: "social-media/#{@company.id}")

          render json: {
            url:          result[:url],
            s3_key:       result[:key],
            filename:     file.original_filename,
            size:         result[:size] || file.size,
            content_type: result[:content_type] || file.content_type
          }
        rescue => e
          Rails.logger.error "[SocialMediaUpload] company=#{@company.id} failed: #{e.class}: #{e.message}"
          render json: { error: 'Upload failed' }, status: :unprocessable_entity
        end
      end
    end
  end
end
