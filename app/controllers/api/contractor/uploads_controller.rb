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

        # One login can work for several dealers, so company_id may pick one,
        # but only one this contractor actually works for.
        company_id = params[:company_id].presence&.to_i || current_contractor.company_id
        unless contractor_company_ids.include?(company_id)
          return render json: { error: 'Access denied' }, status: :forbidden
        end

        # Only a folder name; digits only so it cannot climb out of the company folder.
        assignment_id = params[:assignment_id].to_s[/\A\d+\z/] || 'general'
        folder = "contractor-work-logs/#{company_id}/#{assignment_id}"

        begin
          result = PrivateFiles.upload(file, folder: folder)

          render json: {
            # A short-lived link for the preview. The client posts it back with
            # the work log, and the model stores the reference behind it.
            url: PrivateFiles.url(result[:ref]),
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
        s3_key = params[:s3_key].to_s
        return render json: { error: 'No s3_key provided' }, status: :unprocessable_entity if s3_key.blank?

        # Only files under a company this contractor works for.
        unless s3_key.start_with?('contractor-work-logs/') && contractor_company_ids.any? { |id| PrivateFiles.owned_by?(s3_key, id) }
          return render json: { error: 'Access denied' }, status: :forbidden
        end

        [PrivateFiles.bucket, PrivateFiles.legacy_bucket].uniq.each do |b|
          PrivateFiles.delete(PrivateFiles.ref(s3_key, b))
        end

        head :no_content
      end

      private

      def contractor_company_ids
        @contractor_company_ids ||= all_contractors.pluck(:company_id).compact.uniq
      end
    end
  end
end
