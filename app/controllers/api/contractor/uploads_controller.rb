# frozen_string_literal: true

module Api
  module Contractor
    class UploadsController < BaseController
      # POST /api/contractor/uploads
      def create
        unless params[:file].present?
          return render json: { error: 'No file provided' }, status: :unprocessable_entity
        end

        file = params[:file]

        # Validate file size (max 10MB)
        if file.size > 10.megabytes
          return render json: { error: 'File too large. Maximum size is 10MB' }, status: :unprocessable_entity
        end

        company_id = params[:company_id] || current_contractor.company_id
        assignment_id = params[:assignment_id] || 'general'
        folder = "contractor-work-logs/#{company_id}/#{assignment_id}"

        begin
          service = S3UploadService.new
          result = service.upload(file, folder: folder)

          render json: {
            url: result[:url],
            s3_key: result[:key],
            filename: file.original_filename,
            size: result[:size],
            content_type: result[:content_type]
          }, status: :created
        rescue => e
          Rails.logger.error "Contractor upload failed: #{e.message}"
          render json: { error: "Upload failed: #{e.message}" }, status: :internal_server_error
        end
      end

      # DELETE /api/contractor/uploads
      def destroy
        unless params[:s3_key].present?
          return render json: { error: 'No s3_key provided' }, status: :unprocessable_entity
        end

        service = S3UploadService.new
        service.delete(params[:s3_key])

        head :no_content
      end
    end
  end
end
