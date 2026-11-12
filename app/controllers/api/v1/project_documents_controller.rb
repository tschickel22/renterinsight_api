# frozen_string_literal: true

module Api
  module V1
    # Photos, videos and files on a project, a phase or a sub-task. The dealer
    # sees everything, contractor uploads included; each file says whether the
    # buyer and the contractor see it too (E102, ProjectMedia).
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
        # A phase and everything on its sub-tasks.
        if params[:phase_id].present?
          task_ids = ProjectPhaseTask.where(project_phase_id: params[:phase_id]).pluck(:id)
          docs = docs.where(documentable_type: 'ProjectPhase', documentable_id: params[:phase_id])
                     .or(docs.where(documentable_type: 'ProjectPhaseTask', documentable_id: task_ids))
        end
        docs = docs.where("content_type LIKE 'image/%' OR content_type LIKE 'video/%'") if params[:media_only].present?

        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
        allowed_sorts = %w[created_at title category file_name]
        sort_by = 'created_at' unless allowed_sorts.include?(sort_by)
        docs = docs.order(sort_by => sort_order)

        total_count = docs.count
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 25).to_i, 500].min
        docs = docs.offset((page - 1) * per_page).limit(per_page)
                   .includes(:uploaded_by, :contractor, documentable: :project_phase)

        render json: {
          documents: docs.map { |d| document_json(d) },
          meta: { total_count: total_count, page: page, per_page: per_page,
                  share_media_with_client: @project.share_media_with_client,
                  # The other company on a linked job (E68), for "Shared with ..."
                  link_partner: ProjectLinkDocuments.partner(@project) }
        }
      end

      # GET /api/v1/projects/:project_id/documents/:id
      def show
        return unless authorize_action!('projects', 'read')

        render json: document_json(@document).merge(file_s3_key: @document.file_s3_key)
      end

      # POST /api/v1/projects/:project_id/documents
      def create
        return unless authorize_action!('projects', 'update')

        unless params[:file].present?
          return render json: { error: 'No file provided' }, status: :unprocessable_entity
        end

        file = params[:file]

        # Videos up to 250MB, anything else 25MB.
        max_size = ProjectMedia.max_size_for(file.content_type)
        if file.size > max_size
          return render json: { error: "File too large. Maximum size is #{max_size / 1.megabyte}MB" }, status: :unprocessable_entity
        end

        # The phase or sub-task must be on this project.
        documentable = find_documentable
        return if performed?

        # Upload to S3
        begin
          folder = "projects/#{@company.id}/#{@project.id}/documents"
          s3_result = PrivateFiles.upload(file, folder: folder)

          @document = @project.project_documents.build(
            company_id: @company.id,
            uploaded_by_id: current_user.id,
            source: 'dealer',
            title: params[:title].presence || file.original_filename,
            description: params[:description],
            category: params[:category].presence || ProjectDocument.category_for(s3_result[:content_type] || file.content_type),
            documentable: documentable,
            file_url: s3_result[:ref],
            file_s3_key: s3_result[:key],
            file_name: file.original_filename,
            file_size: s3_result[:size],
            content_type: s3_result[:content_type],
            # nil follows the phase/project setting; a tick is the dealer's choice.
            client_visible: tri_state(:client_visible),
            contractor_visible: tri_state(:contractor_visible),
            metadata: (params[:metadata].respond_to?(:to_unsafe_h) ? params[:metadata].to_unsafe_h : {})
                        .except('link_copy_of', 'link_copy_id', 'link_from', 'project_link_id').deep_stringify_keys
          )
          # On a linked job (E68): installer photos go to the dealer unless
          # unticked; anything else crosses only when marked.
          shared = params.key?(:shared) ? ActiveModel::Type::Boolean.new.cast(params[:shared]) : ProjectLinkDocuments.share_by_default?(@document)
          @document.metadata = @document.metadata.merge('link_shared' => true) if shared

          if @document.save
            ProjectLinkDocumentJob.perform_later(@document.id) if shared
            render json: document_json(@document), status: :created
          else
            # Clean up S3 if save fails
            PrivateFiles.delete(s3_result[:ref])
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

        if params.key?(:shared)
          begin
            ProjectLinkDocuments.set_shared!(@document, ActiveModel::Type::Boolean.new.cast(params[:shared]))
          rescue ArgumentError => e
            return render json: { error: e.message }, status: :unprocessable_entity
          end
        end

        attrs = document_update_params.to_h
        attrs[:client_visible] = tri_state(:client_visible) if params.key?(:client_visible)
        attrs[:contractor_visible] = tri_state(:contractor_visible) if params.key?(:contractor_visible)

        if @document.update(attrs)
          render json: document_json(@document)
        else
          render json: { errors: @document.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/projects/:project_id/documents/:id
      def destroy
        return unless authorize_action!('projects', 'delete')

        # A contractor's file stays stored for their work log; only the
        # project's record of it goes.
        if @document.owns_stored_file?
          # file_url is a reference (or a legacy URL); either names the right bucket.
          PrivateFiles.delete(@document.file_url.presence || @document.file_s3_key)
        end

        @document.update!(is_deleted: true)
        # Its copy on a linked job goes too (E68).
        ProjectLinkDocumentJob.perform_later(@document.id) if @document.metadata&.dig('link_copy_id')
        render json: { message: 'Document deleted' }
      end

      # POST /api/v1/projects/:project_id/documents/notify_client
      # Body: { document_ids: [], note: }
      # Emails the buyer that new photos are on their project. Only files the
      # buyer can actually see count; nothing is sent when there are none.
      def notify_client
        return unless authorize_action!('projects', 'update')

        docs = @project.project_documents.not_deleted.where(id: Array(params[:document_ids]))
                       .includes(documentable: :project_phase).to_a
        visible_phase_ids = @project.project_phases.client_visible.pluck(:id)
        shown = docs.select do |d|
          d.shown_to_client? && (d.phase.nil? || visible_phase_ids.include?(d.phase.id))
        end

        if shown.empty?
          return render json: { error: 'The buyer cannot see any of these files yet. Tick "Buyer sees it" first.' }, status: :unprocessable_entity
        end

        result = ProjectNotificationService.notify_client_media_added(
          @project, shown, sender: current_user, note: params[:note]
        )
        if result[:sent]
          render json: { sent: true, to: result[:to], count: shown.size }
        else
          render json: { error: result[:error] }, status: :unprocessable_entity
        end
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

      # true, false, or nil ("follow the setting") from a param.
      def tri_state(key)
        return nil unless params.key?(key)

        raw = params[key]
        return nil if raw.nil? || raw.to_s == '' || raw.to_s == 'default'

        ActiveModel::Type::Boolean.new.cast(raw)
      end

      # The phase or sub-task named by documentable_type/id, scoped to this
      # project. nil for a file on the whole project. Renders 404 on a miss.
      def find_documentable
        type = params[:documentable_type].presence
        id = params[:documentable_id].presence
        return nil unless type && id

        record =
          case type
          when 'ProjectPhase' then @project.project_phases.find_by(id: id)
          when 'ProjectPhaseTask' then ProjectPhaseTask.joins(:project_phase)
                                                       .where(project_phases: { project_id: @project.id })
                                                       .find_by(id: id)
          when 'ProjectTask' then @project.tasks.find_by(id: id)
          end
        render json: { error: 'That phase or task is not on this project' }, status: :not_found unless record
        record
      end

      def document_json(doc)
        phase = doc.phase
        task = doc.phase_task
        doc.as_json(
          only: %i[id project_id documentable_type documentable_id uploaded_by_id
                   title description category file_url file_name file_size
                   content_type metadata source client_visible contractor_visible created_at updated_at]
        ).merge(
          'phase_id' => phase&.id,
          'phase_name' => phase&.name,
          'task_name' => task&.name,
          'uploaded_by_name' => doc.source == 'contractor' ? doc.contractor&.name : doc.uploaded_by&.full_name,
          'is_media' => doc.media?,
          # What actually happens with the setting applied, for the eye icon.
          'shown_to_client' => doc.shown_to_client?(project_setting: @project.share_media_with_client) &&
                               (phase.nil? || phase.visible_to_client) && @project.client_visible,
          'shown_to_contractor' => doc.shown_to_contractor?
        )
      end
    end
  end
end
