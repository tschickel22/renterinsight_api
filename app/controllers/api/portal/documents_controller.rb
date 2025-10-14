# frozen_string_literal: true

module Api
  module Portal
    class DocumentsController < ApplicationController
      skip_before_action :authenticate
      before_action :authenticate_portal_buyer!
      before_action :set_document, only: [:show, :download, :destroy]
      before_action :authorize_document!, only: [:show, :download, :destroy]
      
      # GET /api/portal/documents
      def index
        documents = buyer_documents
        
        # Filter by category if provided
        if params[:category].present?
          documents = documents.by_category(params[:category])
        end
        
        # Pagination
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 20).to_i, 100].min
        
        total_count = documents.count
        total_pages = (total_count.to_f / per_page).ceil
        
        documents = documents.recent
                            .limit(per_page)
                            .offset((page - 1) * per_page)
        
        render json: {
          ok: true,
          documents: documents.map { |d| DocumentPresenter.list_json(d) },
          pagination: {
            current_page: page,
            total_pages: total_pages,
            total_count: total_count,
            per_page: per_page
          }
        }
      end
      
      # GET /api/portal/documents/:id
      def show
        render json: {
          ok: true,
          document: DocumentPresenter.detail_json(@document)
        }
      end
      
      # POST /api/portal/documents
      def create
        document = PortalDocument.new(document_params)
        document.owner = current_portal_buyer.buyer
        document.uploaded_by = 'buyer'
        
        if document.save
          render json: {
            ok: true,
            message: 'Document uploaded successfully',
            document: DocumentPresenter.list_json(document)
          }, status: :created
        else
          render json: {
            ok: false,
            error: 'Document upload failed',
            errors: document.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      # GET /api/portal/documents/:id/download
      def download
        if @document.file.attached?
          send_data @document.file.download,
                    filename: @document.filename,
                    type: @document.content_type,
                    disposition: 'attachment'
        else
          render json: {
            ok: false,
            error: 'File not found'
          }, status: :not_found
        end
      end
      
      # DELETE /api/portal/documents/:id
      def destroy
        @document.file.purge if @document.file.attached?
        @document.destroy
        
        render json: {
          ok: true,
          message: 'Document deleted successfully'
        }
      end
      
      private
      
      def set_document
        @document = PortalDocument.find_by(id: params[:id])
        unless @document
          render json: { ok: false, error: 'Document not found' }, status: :not_found
        end
      end
      
      def authorize_document!
        buyer = current_portal_buyer.buyer
        
        unless @document.owner == buyer
          render json: { ok: false, error: 'Unauthorized' }, status: :forbidden
        end
      end
      
      def buyer_documents
        PortalDocument.by_owner(current_portal_buyer.buyer)
      end
      
      def document_params
        params.permit(:file, :category, :description, :related_to_type, :related_to_id)
      end
    end
  end
end
