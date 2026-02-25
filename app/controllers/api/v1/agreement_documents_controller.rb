require 'open3'

module Api
  module V1
    class AgreementDocumentsController < ApplicationController
      before_action :set_company_scope

      MAX_FILE_SIZE = 25.megabytes
      ALLOWED_CONTENT_TYPES = %w[
        application/pdf
        application/vnd.openxmlformats-officedocument.wordprocessingml.document
        application/msword
      ].freeze

      DOCX_CONTENT_TYPES = %w[
        application/vnd.openxmlformats-officedocument.wordprocessingml.document
        application/msword
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
        # Also check by extension as a fallback (browsers sometimes misreport content type)
        ext = File.extname(file.original_filename).downcase
        is_word = DOCX_CONTENT_TYPES.include?(content_type) || ['.docx', '.doc'].include?(ext)
        is_pdf = content_type == 'application/pdf' || ext == '.pdf'

        unless is_pdf || is_word
          return render json: { error: 'Only PDF and Word (.docx, .doc) files are allowed' }, status: :unprocessable_entity
        end

        begin
          s3_service = S3UploadService.new
          folder = "agreements/#{@company.id}/documents"

          if is_word
            # Convert DOCX/DOC to PDF, upload both
            upload_word_document(file, s3_service, folder)
          else
            # Upload PDF directly
            upload_pdf_document(file, s3_service, folder)
          end

        rescue DocumentConversionService::ConversionError => e
          Rails.logger.error "Document conversion failed: #{e.message}"
          render json: { error: e.message }, status: :unprocessable_entity
        rescue => e
          Rails.logger.error "Agreement document upload failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          render json: { error: "Upload failed: #{e.message}" }, status: :internal_server_error
        end
      end

      # DELETE /api/v1/agreement_documents/delete
      def delete
        return unless authorize_action!('agreements', 'update')

        s3_key = params[:s3_key]
        unless s3_key.present?
          return render json: { error: 'No s3_key provided' }, status: :unprocessable_entity
        end

        # Security: Only allow deleting files under this company's agreements folder
        unless s3_key.start_with?("agreements/#{@company.id}/")
          return render json: { error: 'Access denied' }, status: :forbidden
        end

        begin
          s3_service = S3UploadService.new
          s3_service.delete(s3_key)
          render json: { message: 'Document deleted' }
        rescue => e
          Rails.logger.error "Agreement document S3 delete failed: #{e.message}"
          render json: { error: "Delete failed: #{e.message}" }, status: :internal_server_error
        end
      end

      # POST /api/v1/agreement_documents/merge
      # Merges multiple uploaded PDFs into a single PDF for signing
      def merge
        return unless authorize_action!('agreements', 'update')

        agreement_id = params[:agreement_id]
        pdf_urls = params[:pdf_urls]

        unless agreement_id.present? && pdf_urls.is_a?(Array) && pdf_urls.length >= 2
          return render json: { error: 'agreement_id and at least 2 pdf_urls are required' }, status: :unprocessable_entity
        end

        agreement = @company.agreements.where(is_deleted: [false, nil]).find_by(id: agreement_id)
        unless agreement
          return render json: { error: 'Agreement not found' }, status: :not_found
        end

        begin
          require 'combine_pdf'
          require 'open-uri'

          combined = CombinePDF.new

          pdf_urls.each_with_index do |url, idx|
            Rails.logger.info "[AgreementDocuments] Merging PDF #{idx + 1}/#{pdf_urls.length}: #{url.truncate(80)}"
            pdf_data = URI.open(url).read
            combined << CombinePDF.parse(pdf_data)
          end

          # Write merged PDF to temp file
          tmp = Tempfile.new(['merged', '.pdf'])
          combined.save(tmp.path)
          tmp.rewind

          # Upload merged PDF to S3
          s3_service = S3UploadService.new
          folder = "agreements/#{@company.id}/documents"

          upload_file = ActionDispatch::Http::UploadedFile.new(
            tempfile: tmp,
            filename: "merged_#{SecureRandom.hex(6)}.pdf",
            type: 'application/pdf'
          )

          s3_result = s3_service.upload(upload_file, folder: folder)

          # Update agreement with merged PDF URL and store individual URLs
          agreement.update!(
            document_url: s3_result[:url],
            document_urls: pdf_urls,
            content_type: 'pdf_upload'
          )

          Rails.logger.info "[AgreementDocuments] Merged #{pdf_urls.length} PDFs for agreement #{agreement_id} → #{s3_result[:url].truncate(80)}"

          render json: {
            document_url: s3_result[:url],
            s3_key: s3_result[:key],
            page_count: combined.pages.length,
            source_count: pdf_urls.length
          }, status: :ok

        rescue CombinePDF::ParsingError => e
          Rails.logger.error "[AgreementDocuments] PDF parse error: #{e.message}"
          render json: { error: "One or more files could not be parsed as PDF: #{e.message}" }, status: :unprocessable_entity
        rescue => e
          Rails.logger.error "[AgreementDocuments] Merge failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          render json: { error: "Merge failed: #{e.message}" }, status: :internal_server_error
        ensure
          tmp&.close
          tmp&.unlink
        end
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

      # Upload a PDF directly to S3
      def upload_pdf_document(file, s3_service, folder)
        s3_result = s3_service.upload(file, folder: folder)

        render json: {
          url: s3_result[:url],
          s3_key: s3_result[:key],
          filename: file.original_filename,
          size: s3_result[:size],
          content_type: 'application/pdf',
          converted: false
        }, status: :created
      end

      # Convert Word doc to PDF, upload both original + PDF to S3
      def upload_word_document(file, s3_service, folder)
        # 1. Upload original Word doc to S3 (for reference/download)
        original_result = s3_service.upload(file, folder: "#{folder}/originals")

        # 2. Convert to PDF
        conversion = DocumentConversionService.to_pdf(file)

        begin
          # 3. Upload the converted PDF to S3
          pdf_file = File.open(conversion[:pdf_path], 'rb')
          # Wrap in an object that looks like an uploaded file for S3UploadService
          pdf_upload = ActionDispatch::Http::UploadedFile.new(
            tempfile: pdf_file,
            filename: conversion[:pdf_filename],
            type: 'application/pdf'
          )

          pdf_result = s3_service.upload(pdf_upload, folder: folder)

          render json: {
            url: pdf_result[:url],              # PDF URL for preview/signing
            s3_key: pdf_result[:key],
            filename: conversion[:pdf_filename],
            size: pdf_result[:size],
            content_type: 'application/pdf',
            converted: true,
            original_url: original_result[:url],  # Original Word doc URL
            original_s3_key: original_result[:key],
            original_filename: file.original_filename,
            original_content_type: file.content_type
          }, status: :created
        ensure
          pdf_file&.close
          FileUtils.rm_rf(conversion[:tmp_dir]) if conversion[:tmp_dir]
        end
      end

    end
  end
end
