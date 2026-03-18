# frozen_string_literal: true

module Api
  module V1
    class CustomFieldUploadsController < ApplicationController
      before_action :set_company_scope

      # POST /api/v1/custom_field_uploads
      # Uploads a file to S3 for use in custom field values (file/image types)
      # Params: file (multipart), module (string), entity_id (integer), field_key (string)
      def create
        return unless authorize_upload!

        unless params[:file].present?
          return render json: { error: 'No file provided' }, status: :unprocessable_entity
        end

        file = params[:file]
        module_name = params[:module] || 'general'
        entity_id = params[:entity_id]
        field_key = params[:field_key]

        # Validate file size (max 10MB)
        max_size = 10.megabytes
        if file.size > max_size
          return render json: { error: "File too large. Maximum size is #{max_size / 1.megabyte}MB" }, status: :unprocessable_entity
        end

        # Validate file type based on custom field type
        field_type = params[:field_type] || 'file'
        if field_type == 'image'
          allowed_types = %w[image/jpeg image/png image/gif image/webp image/svg+xml]
          unless allowed_types.include?(file.content_type)
            return render json: { error: "Invalid image type. Allowed: JPG, PNG, GIF, WebP, SVG" }, status: :unprocessable_entity
          end
        end

        # Upload to S3
        begin
          s3_service = S3UploadService.new
          folder = "custom-fields/#{@company.id}/#{module_name}/#{entity_id || 'new'}"
          s3_result = s3_service.upload(file, folder: folder)

          # Return file metadata for storing in custom_field_values JSONB
          render json: {
            url: s3_result[:url],
            s3_key: s3_result[:key],
            filename: file.original_filename,
            size: s3_result[:size],
            content_type: s3_result[:content_type]
          }
        rescue => e
          Rails.logger.error "Custom field upload failed: #{e.message}"
          render json: { error: "Upload failed: #{e.message}" }, status: :internal_server_error
        end
      end

      # DELETE /api/v1/custom_field_uploads
      # Removes a file from S3
      # Params: s3_key (string)
      def destroy
        return unless authorize_upload!

        s3_key = params[:s3_key]
        unless s3_key.present?
          return render json: { error: 'No s3_key provided' }, status: :unprocessable_entity
        end

        # Security: Only allow deleting files under this company's folder
        unless s3_key.start_with?("custom-fields/#{@company.id}/")
          return render json: { error: 'Access denied' }, status: :forbidden
        end

        begin
          s3_service = S3UploadService.new
          s3_service.delete(s3_key)
          render json: { message: 'File deleted' }
        rescue => e
          Rails.logger.error "Custom field file delete failed: #{e.message}"
          render json: { error: "Delete failed: #{e.message}" }, status: :internal_server_error
        end
      end

      private

      # Module-aware authorization: check 'update' permission on the resource
      # that corresponds to the module param (contractors, leads, contacts, etc.)
      def authorize_upload!
        resource_key = upload_resource_key
        authorize_action!(resource_key, 'update')
      end

      # Map module param to RBAC resource key
      def upload_resource_key
        module_map = {
          'contractors' => 'contractors',
          'leads'       => 'leads',
          'contacts'    => 'contacts',
          'accounts'    => 'accounts',
          'deals'       => 'crm',
          'quotes'      => 'quotes',
          'vehicles'    => 'inventory',
          'parts'       => 'parts',
        }
        module_map[params[:module]] || 'crm'
      end
    end
  end
end
