# frozen_string_literal: true

module Api
  module V1
    class ProjectDocumentsController < ApplicationController
      before_action :set_company_scope
      before_action :set_project
      before_action :set_document, only: %i[show update destroy]

      # GET /api/v1/projects/:project_id/documents
      def index
        return unless authorize_action!('projects', 'read')

        docs = @project.project_documents.not_deleted

        # Filters
        docs = docs.by_category(params[:category])
        if params[:documentable_type].present?
          docs = docs.where(documentable_type: params[:documentable_type])
          docs = docs.where(documentable_id: params[:documentable_id]) if params[:documentable_id].present?
        end

        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
        allowed_sorts = %w[created_at title category file_name]
        sort_by = 'created_at' unless allowed_sorts.include?(sort_by)
        docs = docs.order(sort_by => sort_order)

        total_count = docs.count
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 25).to_i
        docs = docs.offset((page - 1) * per_page).limit(per_page)

        render json: {
          documents: docs.as_json(
            only: %i[id project_id documentable_type documentable_id uploaded_by_id
                     title description category file_url file_name file_size
                     content_type metadata created_at updated_at]
          ),
          meta: { total_count: total_count, page: page, per_page: per_page }
        }
      end

      # GET /api/v1/projects/:project_id/documents/:id
      def show
        return unless authorize_action!('projects', 'read')

        render json: @document.as_json(
          only: %i[id project_id documentable_type documentable_id uploaded_by_id
                   title description category file_url file_s3_key file_name
                   file_size content_type metadata created_at updated_at]
        )
      end

      # POST /api/v1/projects/:project_id/documents
      def create
        return unless authorize_action!('projects', 'update')

        unless params[:file].present?
          return render json: { error: 'No file provided' }, status: :unprocessable_entity
        end

        file = params[:file]

        # Validate file size (max 25MB for project documents)
        max_size = 25.megabytes
        if file.size > max_size
          return render json: { error: "File too large. Maximum size is #{max_size / 1.megabyte}MB" }, status: :unprocessable_entity
        end

        # Upload to S3
        begin
          s3_service = S3UploadService.new
          folder = "projects/#{@company.id}/#{@project.id}/documents"
          s3_result = s3_service.upload(file, folder: folder)

          @document = @project.project_documents.build(
            company_id: @company.id,
            uploaded_by_id: current_user.id,
            title: params[:title] || file.original_filename,
            description: params[:description],
            category: params[:category] || 'other',
            documentable_type: params[:documentable_type],
            documentable_id: params[:documentable_id],
            file_url: s3_result[:url],
            file_s3_key: s3_result[:key],
            file_name: file.original_filename,
            file_size: s3_result[:size],
            content_type: s3_result[:content_type],
            metadata: params[:metadata] || {}
          )

          if @document.save
            render json: @document.as_json(
              only: %i[id project_id documentable_type documentable_id uploaded_by_id
                       title description category file_url file_name file_size
                       content_type metadata created_at updated_at]
            ), status: :created
          else
            # Clean up S3 if save fails
            s3_service.delete(s3_result[:key])
            render json: { errors: @document.errors.full_messages }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "Project document upload failed: #{e.message}"
          render json: { error: "Upload failed: #{e.message}" }, status: :internal_server_error
        end
      end

      # PATCH/PUT /api/v1/projects/:project_id/documents/:id
      def update
        return unless authorize_action!('projects', 'update')

        if @document.update(document_update_params)
          render json: @document.as_json(
            only: %i[id project_id documentable_type documentable_id uploaded_by_id
                     title description category file_url file_name file_size
                     content_type metadata created_at updated_at]
          )
        else
          render json: { errors: @document.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/projects/:project_id/documents/:id
      def destroy
        return unless authorize_action!('projects', 'delete')

        # Delete from S3
        if @document.file_s3_key.present?
          s3_service = S3UploadService.new
          s3_service.delete(@document.file_s3_key)
        end

        @document.update!(is_deleted: true)
        render json: { message: 'Document deleted' }
      end

      private

      def set_project
        @project = @company.projects.not_deleted.find(params[:project_id])
      end

      def set_document
        @document = @project.project_documents.not_deleted.find(params[:id])
      end

      def document_update_params
        params.permit(:title, :description, :category)
      end
    end
  end
end
