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

      def create
        return unless authorize_action!('data_import_export', 'create')

        unless ImportExport::ModuleRegistry.config_for(params[:module_type])
          return render json: { error: "Unknown module: #{params[:module_type]}" }, status: :unprocessable_entity
        end

        job = ExportJob.create!(
          company_id: @company.id,
          user_id: current_user.id,
          module_type: params[:module_type],
          format: params[:format].presence || 'csv',
          filters: params[:filters].is_a?(ActionController::Parameters) ? params[:filters].to_unsafe_h : {},
          selected_fields: params[:selected_fields].is_a?(Array) ? params[:selected_fields] : [],
          status: 'pending'
        )
        ProcessExportJob.perform_later(job.id)
        render json: serialize(job), status: :created
      end

      # GET /api/v1/export_jobs/:id/download
      def download
        return unless authorize_action!('data_import_export', 'read')
        return render json: { error: 'Not ready' }, status: :unprocessable_entity unless @job.status == 'completed' && @job.file_url.present?

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

      def serialize(j)
        {
          id: j.id,
          module_type: j.module_type,
          status: j.status,
          format: j.format,
          row_count: j.row_count,
          file_url: j.file_url,
          started_at: j.started_at,
          completed_at: j.completed_at,
          created_at: j.created_at
        }
      end
    end
  end
end
