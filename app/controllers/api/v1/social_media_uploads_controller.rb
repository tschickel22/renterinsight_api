# frozen_string_literal: true

module Api
  module V1
    # S3 upload endpoint for social media creatives (posts, ads). Reuses the
    # same S3UploadService + env-var setup as CustomFieldUploadsController so
    # bucket/region/credential handling stays consistent across the app.
    class SocialMediaUploadsController < ApplicationController
      before_action :set_company_scope

      IMAGE_CONTENT_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze
      # The formats Facebook reliably accepts for a Page video post. MOV is
      # included because it's what phones produce.
      VIDEO_CONTENT_TYPES = %w[video/mp4 video/quicktime video/x-m4v].freeze
      ALLOWED_CONTENT_TYPES = (IMAGE_CONTENT_TYPES + VIDEO_CONTENT_TYPES).freeze

      MAX_IMAGE_SIZE = 10.megabytes
      # Video is uploaded through this app before going to S3, so the ceiling is
      # what the web process can hold, not what Facebook accepts (far more).
      MAX_VIDEO_SIZE = 100.megabytes

      # POST /api/v1/social-media/upload
      def create
        return unless authorize_action!('social_posts', 'create')

        file = params[:file]
        return render json: { error: 'No file provided' }, status: :bad_request unless file.present?

        unless ALLOWED_CONTENT_TYPES.include?(file.content_type)
          return render json: {
            error: 'Only images (JPEG, PNG, GIF, WebP) and videos (MP4, MOV) are allowed'
          }, status: :unprocessable_entity
        end

        video = VIDEO_CONTENT_TYPES.include?(file.content_type)
        limit = video ? MAX_VIDEO_SIZE : MAX_IMAGE_SIZE

        if file.size > limit
          return render json: {
            error: "#{video ? 'Video' : 'File'} must be under #{limit / 1.megabyte}MB"
          }, status: :unprocessable_entity
        end

        begin
          result = S3UploadService.new.upload(file, folder: "social-media/#{@company.id}")

          render json: {
            url:          result[:url],
            s3_key:       result[:key],
            filename:     file.original_filename,
            size:         result[:size] || file.size,
            content_type: result[:content_type] || file.content_type,
            media_type:   video ? 'video' : 'image'
          }
        rescue => e
          Rails.logger.error "[SocialMediaUpload] company=#{@company.id} failed: #{e.class}: #{e.message}"
          render json: { error: 'Upload failed' }, status: :unprocessable_entity
        end
      end
    end
  end
end
