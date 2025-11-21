# frozen_string_literal: true

module Api
  module Admin
    class DocumentsController < ApplicationController
      before_action :authenticate_user!
      before_action :require_admin_access!
      before_action :set_company_scope
      before_action :set_document, only: [:show, :update, :destroy, :download]

      def index
        documents = company_scoped_documents.includes(:owner).order(created_at: :desc)
        
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          owner_ids = company_scoped_portal_accesses.where('email ILIKE ?', search_term).pluck(:id)
          documents = documents.where(
            'portal_documents.description ILIKE ? OR portal_documents.category ILIKE ? OR owner_id IN (?)',
            search_term, search_term, owner_ids
          )
        end
        
        documents = documents.where(category: params[:category]) if params[:category].present?
        documents = documents.where(owner_id: params[:buyer_id]) if params[:buyer_id].present?
        
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
        buyer_portal_access = company_scoped_portal_accesses.find_by(id: params[:buyer_id])
        return render json: { error: 'Client not found in your company' }, status: :not_found unless buyer_portal_access
        
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

      def require_admin_access!
        unless current_user&.admin? || current_user&.platform_admin? || current_user&.super_admin?
          render json: { error: 'Forbidden - Admin access required' }, status: :forbidden
          return false
        end
        true
      end

      def set_document
        @document = company_scoped_documents.find_by(id: params[:id])
        unless @document
          render json: { error: 'Document not found' }, status: :not_found
        end
      end

      def company_scoped_portal_accesses
        lead_ids = @company.leads.pluck(:id)
        contact_ids = @company.contacts.pluck(:id)

        BuyerPortalAccess.where(
          "(buyer_type = 'Lead' AND buyer_id IN (?)) OR (buyer_type = 'Contact' AND buyer_id IN (?))",
          lead_ids,
          contact_ids
        )
      end

      def company_scoped_documents
        portal_access_ids = company_scoped_portal_accesses.pluck(:id)
        PortalDocument.where(owner_type: 'BuyerPortalAccess', owner_id: portal_access_ids)
      end

      def update_params
        params.permit(:description, :category, :document_name, :admin_notes)
      end

      def document_json(doc)
        buyer_portal_access = doc.owner
        return nil unless buyer_portal_access
        
        actual_buyer = find_actual_buyer(buyer_portal_access)
        buyer_name = extract_buyer_name(actual_buyer, buyer_portal_access)
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

      def find_actual_buyer(buyer_portal_access)
        case buyer_portal_access.buyer_type
        when 'Lead'
          @company.leads.find_by(id: buyer_portal_access.buyer_id)
        when 'Contact'
          @company.contacts.find_by(id: buyer_portal_access.buyer_id)
        end
      end

      def extract_buyer_name(actual_buyer, buyer_portal_access)
        return buyer_portal_access.email.split('@').first unless actual_buyer

        if actual_buyer.is_a?(Lead)
          name = [actual_buyer.first_name, actual_buyer.last_name].compact.join(' ')
          name.presence || actual_buyer.email&.split('@')&.first
        elsif actual_buyer.respond_to?(:name)
          actual_buyer.name
        elsif actual_buyer.respond_to?(:contact_name)
          actual_buyer.contact_name
        elsif actual_buyer.respond_to?(:first_name)
          [actual_buyer.first_name, actual_buyer.last_name].compact.join(' ')
        else
          buyer_portal_access.email.split('@').first
        end
      end
    end
  end
end
