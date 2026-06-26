# frozen_string_literal: true

module Api
  module V1
    # Nested under /api/v1/vehicles/:vehicle_id/documents.
    # See VehicleDocument for the 3-tier visibility contract — `internal` is
    # always the safe default; `customer` and `public` are opt-in per document.
    class VehicleDocumentsController < ApplicationController
      include RbacAuthorization
      rbac_resource :inventory,
        read_actions:   [:index, :show],
        create_actions: [:create],
        update_actions: [:update],
        delete_actions: [:destroy]

      before_action :set_company
      before_action :set_vehicle
      before_action :set_document, only: [:show, :update, :destroy]

      # GET /api/v1/vehicles/:vehicle_id/documents
      def index
        return unless authorize_action!('inventory', 'read')

        docs = @vehicle.documents
        docs = docs.where(visibility: params[:visibility]) if params[:visibility].present?
        docs = docs.where(category: params[:category]) if params[:category].present?

        render json: { documents: docs.order(created_at: :desc).map { |d| document_json(d) } }
      end

      # GET /api/v1/vehicles/:vehicle_id/documents/:id
      def show
        return unless authorize_action!('inventory', 'read')
        render json: { document: document_json(@document) }
      end

      # POST /api/v1/vehicles/:vehicle_id/documents
      def create
        return unless authorize_action!('inventory', 'create')

        file = params[:file]
        attrs = document_params.to_h

        if file.present?
          if file.size > 25.megabytes
            return render json: { error: 'File size exceeds 25MB limit' }, status: :unprocessable_entity
          end

          begin
            result = S3UploadService.new.upload(file, folder: "vehicles/#{@company.id}/#{@vehicle.id}/documents")
            attrs[:file_url] = result[:url]
            attrs[:file_content_type] = file.content_type
            attrs[:file_size] = file.size
            attrs[:title] = attrs[:title].presence || file.original_filename
          rescue => e
            Rails.logger.error "[VehicleDocuments] S3 upload failed: #{e.message}"
            return render json: { error: 'Failed to upload file' }, status: :unprocessable_entity
          end
        end

        doc = @vehicle.documents.new(attrs)
        doc.uploaded_by_user = current_user

        if doc.save
          render json: { document: document_json(doc) }, status: :created
        else
          render json: { errors: doc.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/vehicles/:vehicle_id/documents/:id
      def update
        return unless authorize_action!('inventory', 'update')

        if @document.update(document_params)
          render json: { document: document_json(@document) }
        else
          render json: { errors: @document.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/vehicles/:vehicle_id/documents/:id
      def destroy
        return unless authorize_action!('inventory', 'delete')
        @document.destroy
        head :no_content
      end

      private

      def set_company
        company_id = current_company_id
        unless company_id.present?
          render json: { error: 'No company context' }, status: :forbidden
          return
        end

        @company = ::Company.find_by(id: company_id)
        render(json: { error: 'Company not found' }, status: :not_found) and return unless @company
      end

      def set_vehicle
        @vehicle = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            @company.vehicles.active.where('location_id IN (?) OR location_id IS NULL', location_ids).find(params[:vehicle_id])
          else
            @company.vehicles.active.find(params[:vehicle_id])
          end
        else
          @company.vehicles.active.find(params[:vehicle_id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Vehicle not found or access denied' }, status: :not_found
      end

      def set_document
        @document = @vehicle.documents.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Document not found' }, status: :not_found
      end

      def document_params
        # The create flow posts multipart/form-data with fields at the top level
        # (file, title, category, visibility); the update flow nests them under
        # `document`. Multipart params are never auto-wrapped, so accept both shapes.
        source = params[:document].present? ? params.require(:document) : params
        source.permit(:title, :category, :visibility, :file_url, :file_content_type, :file_size)
      end

      def document_json(doc)
        {
          id: doc.id,
          vehicle_id: doc.vehicle_id,
          title: doc.title,
          category: doc.category,
          visibility: doc.visibility,
          file_url: doc.file_url,
          file_content_type: doc.file_content_type,
          file_size: doc.file_size,
          uploaded_by_user_id: doc.uploaded_by_user_id,
          created_at: doc.created_at,
          updated_at: doc.updated_at
        }
      end
    end
  end
end
