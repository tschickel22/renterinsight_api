# frozen_string_literal: true

module Api
  module V1
    class ExportJobsController < ApplicationController
      before_action :set_company_scope
      before_action :set_job, only: %i[show download]

      def index
        return unless authorize_action!('data_import_export', 'read')

        jobs = ExportJob.where(company_id: @company.id).recent.limit(100)
        render json: { items: jobs.map { |j| serialize(j) } }
      end

      def show
        return unless authorize_action!('data_import_export', 'read')
        render json: serialize(@job)
      end

      # GET /api/v1/export_jobs/policy
      # Lets the builder render only what this tenant is allowed to do, and
      # show the terms the user is about to assent to.
      def policy
        return unless authorize_action!('data_import_export', 'read')

        render json: {
          allowed_formats:      ImportExport::ExportPolicy.allowed_formats(@company),
          daily_limit:          ImportExport::ExportPolicy.daily_limit(@company),
          remaining_today:      ImportExport::ExportPolicy.remaining_today(@company, current_user),
          max_export_rows:      ImportExport::ExportPolicy.row_cap(@company),
          acknowledgement_text: ImportExport::ExportPolicy::ACKNOWLEDGEMENT_TEXT
        }
      end

      def create
        return unless authorize_action!('data_import_export', 'create')

        unless ImportExport::ModuleRegistry.config_for(params[:module_type])
          return render json: { error: "Unknown module: #{params[:module_type]}" }, status: :unprocessable_entity
        end

        format = params[:format].presence || 'csv'

        unless ImportExport::ExportPolicy.format_allowed?(@company, format)
          return render json: {
            error: "The #{format.to_s.upcase} export format is not enabled for your account. " \
                   'Contact support if you need it.',
            allowed_formats: ImportExport::ExportPolicy.allowed_formats(@company)
          }, status: :forbidden
        end

        # An export is an assented act, not a silent one. Without this the
        # record cannot show who agreed to what, which is the whole point.
        unless ActiveModel::Type::Boolean.new.cast(params[:acknowledged])
          return render json: {
            error: 'You must acknowledge the export terms before starting an export.',
            acknowledgement_text: ImportExport::ExportPolicy::ACKNOWLEDGEMENT_TEXT
          }, status: :unprocessable_entity
        end

        if ImportExport::ExportPolicy.rate_limited?(@company, current_user)
          return render json: {
            error: "You have reached the export limit of " \
                   "#{ImportExport::ExportPolicy.daily_limit(@company)} per 24 hours.",
            remaining_today: 0
          }, status: :too_many_requests
        end

        # Filtered again here even though the field list the UI was given is
        # already curated, so a hand-built request cannot reach an excluded
        # column.
        requested_fields = params[:selected_fields].is_a?(Array) ? params[:selected_fields] : []
        safe_fields      = ImportExport::ExportPolicy.filter_keys(requested_fields)

        job = ExportJob.create!(
          company_id: @company.id,
          user_id: current_user.id,
          module_type: params[:module_type],
          format: format,
          filters: params[:filters].is_a?(ActionController::Parameters) ? params[:filters].to_unsafe_h : {},
          selected_fields: safe_fields,
          status: 'pending',
          acknowledged_at: Time.current,
          acknowledgement_text: ImportExport::ExportPolicy::ACKNOWLEDGEMENT_TEXT,
          watermark_token: ImportExport::ExportPolicy.new_watermark_token,
          requested_ip: request.remote_ip
        )

        log_export_activity!(
          job,
          action: 'export_requested',
          description: "Requested #{job.format.upcase} export of #{module_label(job)} " \
                       "(#{safe_fields.size} fields)"
        )

        ProcessExportJob.perform_later(job.id)
        render json: serialize(job), status: :created
      end

      # GET /api/v1/export_jobs/:id/download
      def download
        return unless authorize_action!('data_import_export', 'read')
        return render json: { error: 'Not ready' }, status: :unprocessable_entity unless @job.status == 'completed' && @job.file_url.present?

        @job.update_columns(
          downloaded_at: Time.current,
          download_count: @job.download_count.to_i + 1
        )

        log_export_activity!(
          @job,
          action: 'export_downloaded',
          description: "Downloaded #{@job.format.upcase} export of #{module_label(@job)} " \
                       "(#{@job.row_count} rows)"
        )

        if File.exist?(@job.file_url.to_s)
          send_file @job.file_url, disposition: 'attachment'
        else
          url = S3UploadService.new.presigned_url(@job.file_url)
          render json: { url: url }
        end
      end

      private

      def set_job
        @job = ExportJob.find_by(id: params[:id], company_id: @company.id)
        render json: { error: 'Not found' }, status: :not_found unless @job
      end

      def module_label(job)
        cfg = ImportExport::ModuleRegistry.config_for(job.module_type)
        (cfg && cfg[:label]).presence || job.module_type.to_s.titleize
      end

      # Exports previously left no audit trail at all. The only evidence one
      # happened was the export_jobs row itself. Every request and download now
      # lands in activity_logs alongside the rest of the tenant's history.
      def log_export_activity!(job, action:, description:)
        ActivityLog.create!(
          company_id: @company.id,
          user_id: job.user_id,
          action: action,
          module_name: 'data_import_export',
          entity_type_label: 'Export',
          description: description,
          ip_address: request.remote_ip,
          metadata: {
            'export_job_id'   => job.id,
            'module_type'     => job.module_type.to_s,
            'format'          => job.format.to_s,
            'field_count'     => job.selected_fields.size,
            'row_count'       => job.row_count,
            'watermark_token' => job.watermark_token,
            'filters'         => job.filters
          }
        )
      rescue StandardError => e
        Rails.logger.warn "[ExportJobsController] Failed to write #{action} ActivityLog for job ##{job.id}: #{e.message}"
      end

      def serialize(j)
        {
          id: j.id,
          module_type: j.module_type,
          status: j.status,
          format: j.format,
          row_count: j.row_count,
          file_url: j.file_url,
          watermark_token: j.watermark_token,
          acknowledged_at: j.acknowledged_at,
          downloaded_at: j.downloaded_at,
          download_count: j.download_count,
          started_at: j.started_at,
          completed_at: j.completed_at,
          created_at: j.created_at
        }
      end
    end
  end
end
