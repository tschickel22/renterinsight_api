module Api
  module Admin
    class DocumentsController < ApplicationController
      before_action :set_document, only: [:show, :update, :destroy, :download]

      def index
        # Get documents with owner (buyer_portal_access)
        documents = PortalDocument.where(owner_type: 'BuyerPortalAccess').includes(:owner).order(created_at: :desc)
        
        # Apply search filter
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          # Join with buyer_portal_accesses
          owner_ids = BuyerPortalAccess.where('email LIKE ?', search_term).pluck(:id)
          documents = documents.where(
            'portal_documents.description LIKE ? OR portal_documents.category LIKE ? OR owner_id IN (?)',
            search_term, search_term, owner_ids
          )
        end
        
        # Apply category filter
        documents = documents.where(category: params[:category]) if params[:category].present?
        
        # Apply buyer_id filter
        documents = documents.where(owner_id: params[:buyer_id]) if params[:buyer_id].present?
        
        # Pagination
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 20).to_i
        total = documents.count
        documents = documents.offset((page - 1) * per_page).limit(per_page)
        
        render json: {
          documents: documents.map { |doc| document_json(doc) },
          total: total,
          page: page,
          per_page: per_page
        }
      end

      def show
        render json: { document: document_json(@document) }
      end

      def create
        buyer_portal_access = BuyerPortalAccess.find_by(id: params[:buyer_id])
        return render json: { error: 'Client not found' }, status: :not_found unless buyer_portal_access
        
        @document = PortalDocument.new(
          owner: buyer_portal_access,
          document_name: params[:document_name] || params[:title],
          category: params[:category],
          description: params[:description],
          admin_notes: params[:admin_notes],
          uploaded_by: current_user&.email || 'Admin',
          uploaded_at: Time.current
        )
        
        @document.file.attach(params[:file]) if params[:file].present?
        
        if @document.save
          render json: { document: document_json(@document) }, status: :created
        else
          render json: { errors: @document.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        if @document.update(update_params)
          render json: { document: document_json(@document) }
        else
          render json: { errors: @document.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @document.destroy
        head :no_content
      end

      def download
        if @document.file.attached?
          send_data @document.file.download,
                    filename: @document.file.filename.to_s,
                    type: @document.file.content_type,
                    disposition: 'attachment'
        else
          render json: { error: 'No file attached' }, status: :not_found
        end
      end

      private

      def set_document
        @document = PortalDocument.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Document not found' }, status: :not_found
      end

      def update_params
        params.permit(:description, :category, :document_name, :admin_notes)
      end

      def document_json(doc)
        buyer_portal_access = doc.owner
        
        # Get the actual buyer record
        actual_buyer = begin
          buyer_portal_access.buyer_type.constantize.find_by(id: buyer_portal_access.buyer_id)
        rescue
          nil
        end
        
        # Build buyer name from available fields
        if actual_buyer.is_a?(Lead)
          buyer_name = [actual_buyer.first_name, actual_buyer.last_name].compact.join(' ')
          buyer_name = actual_buyer.email.split('@').first if buyer_name.blank?
        elsif actual_buyer.respond_to?(:name)
          buyer_name = actual_buyer.name
        elsif actual_buyer.respond_to?(:contact_name)
          buyer_name = actual_buyer.contact_name
        elsif actual_buyer.respond_to?(:first_name)
          buyer_name = [actual_buyer.first_name, actual_buyer.last_name].compact.join(' ')
        else
          buyer_name = buyer_portal_access.email.split('@').first
        end
        
        # Determine if buyer uploaded based on uploaded_by field
        is_buyer_uploaded = doc.uploaded_by == 'buyer'
        
        {
          id: doc.id,
          buyer_id: doc.owner_id,
          buyer_name: buyer_name.presence || buyer_portal_access.email.split('@').first,
          buyer_email: buyer_portal_access.email,
          title: doc.document_name.presence || (doc.file.attached? ? doc.file.filename.to_s : (doc.description || 'Untitled')),
          document_name: doc.document_name,
          description: doc.description,
          notes: doc.notes,
          admin_notes: doc.admin_notes,
          category: doc.category || 'other',
          file_name: doc.file.attached? ? doc.file.filename.to_s : '',
          file_size: doc.file.attached? ? doc.file.byte_size : 0,
          content_type: doc.file.attached? ? doc.file.content_type : '',
          uploaded_by: doc.uploaded_by || 'System',
          uploaded_at: doc.uploaded_at || doc.created_at,
          is_buyer_uploaded: is_buyer_uploaded,
          status: 'active'
        }
      end
    end
  end
end
