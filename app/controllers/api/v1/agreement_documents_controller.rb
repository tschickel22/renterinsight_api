module Api
  module V1
    class AgreementDocumentsController < ApplicationController
      before_action :set_company_scope

      MAX_FILE_SIZE = 25.megabytes
      ALLOWED_CONTENT_TYPES = %w[
        application/pdf
        application/vnd.openxmlformats-officedocument.wordprocessingml.document
      ].freeze

      # POST /api/v1/agreement_documents/upload
      def upload
        return unless authorize_action!('agreements', 'create')

        file = params[:document] || params[:file]
        unless file.present?
          return render json: { error: 'No file provided' }, status: :unprocessable_entity
        end

        if file.size > MAX_FILE_SIZE
          return render json: { error: "File size exceeds maximum (#{MAX_FILE_SIZE / 1.megabyte}MB)" }, status: :unprocessable_entity
        end

        content_type = file.content_type
        unless ALLOWED_CONTENT_TYPES.include?(content_type)
          return render json: { error: 'Only PDF and DOCX files are allowed' }, status: :unprocessable_entity
        end

        extension = File.extname(file.original_filename)
        filename = "#{SecureRandom.uuid}#{extension}"
        upload_base = ENV['UPLOAD_PATH'] || Rails.root.join('public', 'uploads')
        path = "#{@company.id}/agreements/documents/#{filename}"
        full_path = File.join(upload_base, path)

        FileUtils.mkdir_p(File.dirname(full_path))
        File.open(full_path, 'wb') { |f| f.write(file.read) }

        render json: {
          url: "/uploads/#{path}",
          filename: file.original_filename,
          size: file.size,
          content_type: content_type
        }, status: :created
      rescue => e
        Rails.logger.error "Error in agreement_documents#upload: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: { error: 'Failed to upload document' }, status: :internal_server_error
      end

      # POST /api/v1/agreement_documents/merge_preview
      def merge_preview
        return unless authorize_action!('agreements', 'read')

        merge_values = params[:merge_field_values] || {}
        document_url = params[:document_url]

        render json: {
          document_url: document_url,
          merge_field_values: merge_values,
          preview_available: false,
          message: 'PDF merge preview will be available when the document service is implemented'
        }
      end

      private

      def set_company_scope
        unless current_user
          return render json: { error: 'Authentication required' }, status: :unauthorized
        end

        @company = Company.find_by(id: current_company_id)
        unless @company
          return render json: { error: 'Company not found' }, status: :not_found
        end
      end
    end
  end
end
