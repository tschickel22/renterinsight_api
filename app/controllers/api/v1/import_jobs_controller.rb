# frozen_string_literal: true

module Api
  module V1
    class ImportJobsController < ApplicationController
      before_action :set_company_scope
      before_action :set_job, only: %i[show preview start rollback destroy]

      # GET /api/v1/import_jobs
      def index
        return unless authorize_action!('data_import_export', 'read')

        jobs = ImportJob.where(company_id: @company.id).recent
        jobs = jobs.where(module_type: params[:module_type]) if params[:module_type].present?
        jobs = jobs.where(status: params[:status]) if params[:status].present?

        render json: { items: jobs.limit(100).map { |j| serialize(j) } }
      end

      # GET /api/v1/import_jobs/:id
      def show
        return unless authorize_action!('data_import_export', 'read')
        render json: serialize(@job, include_errors: true)
      end

      # POST /api/v1/import_jobs
      # Multipart: file, image_zip (optional), module_type, duplicate_strategy
      def create
        return unless authorize_action!('data_import_export', 'create')

        file = params[:file]
        return render json: { error: 'file is required' }, status: :unprocessable_entity unless file
        return render json: { error: 'module_type is required' }, status: :unprocessable_entity if params[:module_type].blank?
        unless ImportExport::ModuleRegistry.config_for(params[:module_type])
          return render json: { error: "Unknown module: #{params[:module_type]}" }, status: :unprocessable_entity
        end

        source_key = upload_to_s3(file, folder: "imports/#{@company.id}")
        zip_key    = params[:image_zip].present? ? upload_to_s3(params[:image_zip], folder: "imports/#{@company.id}/images") : nil

        job = ImportJob.create!(
          company_id: @company.id,
          user_id: current_user.id,
          module_type: params[:module_type],
          status: 'pending',
          source_filename: file.original_filename,
          source_file_url: source_key,
          image_zip_url: zip_key,
          duplicate_strategy: params[:duplicate_strategy].presence || 'skip',
          duplicate_match_fields: parse_array(params[:duplicate_match_fields]),
          options: build_import_options
        )

        render json: serialize(job), status: :created
      rescue StandardError => e
        Rails.logger.error "[ImportJobs#create] #{e.class}: #{e.message}"
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/import_jobs/:id/preview
      # Parses first 10 rows + suggests mapping. Does NOT import.
      def preview
        return unless authorize_action!('data_import_export', 'read')

        path   = ImportExport::S3Helper.download_to_tempfile(@job.source_file_url)
        parsed = ImportExport::CsvParser.new(path).parse
        fields = ImportExport::ModuleRegistry.fields_for(@job.module_type, company_id: @company.id, for_import: true)
        mapper = ImportExport::FieldMapper.new(parsed[:headers], fields).call

        render json: {
          headers: parsed[:headers],
          sample_rows: parsed[:rows].first(10),
          total_rows: parsed[:total_rows],
          fields: fields,
          suggested_mapping: mapper[:suggested_mapping],
          unmapped_headers: mapper[:unmapped_headers]
        }
      rescue StandardError => e
        Rails.logger.error "[ImportJobs#preview] #{e.message}"
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/import_jobs/:id/start
      def start
        return unless authorize_action!('data_import_export', 'update')

        mapping = params[:column_mapping]&.to_unsafe_h || {}
        return render json: { error: 'column_mapping is required' }, status: :unprocessable_entity if mapping.empty?

        @job.update!(
          column_mapping: mapping,
          duplicate_strategy: params[:duplicate_strategy].presence || @job.duplicate_strategy || 'skip',
          duplicate_match_fields: parse_array(params[:duplicate_match_fields]).presence || @job.duplicate_match_fields
        )
        ProcessImportJob.perform_later(@job.id)
        render json: serialize(@job)
      end

      # POST /api/v1/import_jobs/:id/rollback
      def rollback
        return unless authorize_action!('data_import_export', 'delete')

        unless @job.can_rollback?
          return render json: { error: 'Job is not rollbackable (must be completed within 30 days with created records)' }, status: :unprocessable_entity
        end
        ProcessRollbackJob.perform_later(@job.id)
        render json: { message: 'Rollback queued', id: @job.id }
      end

      # DELETE /api/v1/import_jobs/:id
      def destroy
        return unless authorize_action!('data_import_export', 'delete')
        @job.destroy!
        render json: { message: 'Deleted' }
      end

      private

      def set_job
        @job = ImportJob.find_by(id: params[:id], company_id: @company.id)
        render json: { error: 'Not found' }, status: :not_found unless @job
      end

      def upload_to_s3(file, folder:)
        svc = S3UploadService.new
        result = svc.upload(file, folder: folder)
        result[:key]
      end

      def parse_array(val)
        return [] if val.blank?
        return val if val.is_a?(Array)
        val.to_s.split(',').map(&:strip).reject(&:empty?)
      end

      def parse_options(val)
        return {} if val.blank?
        return val.to_unsafe_h if val.is_a?(ActionController::Parameters)
        return val if val.is_a?(Hash)
        JSON.parse(val.to_s)
      rescue JSON::ParserError
        {}
      end

      # Merge frontend-provided options with request context defaults.
      # location_id falls back to the user's current location (X-Location-ID header).
      # owner_id falls back to the importing user.
      def build_import_options
        opts = parse_options(params[:options])
        opts['location_id'] ||= Current.location_id if Current.location_id.present?
        opts['owner_id']    ||= current_user.id
        opts
      end

      def serialize(job, include_errors: false)
        h = {
          id: job.id,
          module_type: job.module_type,
          status: job.status,
          source_filename: job.source_filename,
          total_rows: job.total_rows,
          processed_rows: job.processed_rows,
          success_count: job.success_count,
          error_count: job.error_count,
          skipped_count: job.skipped_count,
          progress_percent: job.progress_percent,
          duplicate_strategy: job.duplicate_strategy,
          duplicate_match_fields: job.duplicate_match_fields,
          column_mapping: job.column_mapping,
          can_rollback: job.can_rollback?,
          started_at: job.started_at,
          completed_at: job.completed_at,
          created_at: job.created_at
        }
        h[:error_log] = job.error_log if include_errors
        h
      end
    end
  end
end
