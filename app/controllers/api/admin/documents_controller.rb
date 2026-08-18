# frozen_string_literal: true

module Api
  module Admin
    class DocumentsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_company_scope
      before_action :set_document, only: [:show, :update, :destroy, :download]

      def index
        return unless authorize_action!('documents', 'read')
        
        documents = company_scoped_documents.includes(:owner).order(created_at: :desc)
        
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          # Search in Contact names and emails
          contact_ids = @company.contacts.where(
            'first_name ILIKE ? OR last_name ILIKE ? OR email ILIKE ?',
            search_term, search_term, search_term
          ).pluck(:id)
          documents = documents.where(
            'portal_documents.document_name ILIKE ? OR portal_documents.description ILIKE ? OR portal_documents.category ILIKE ? OR owner_id IN (?)',
            search_term, search_term, search_term, contact_ids
          )
        end
        
        documents = documents.where(category: params[:category]) if params[:category].present?
        documents = documents.where(owner_id: params[:buyer_id]) if params[:buyer_id].present?
        
        # Pagination
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 20).to_i
        per_page = [per_page, 200].min  # Cap at 200
        total = documents.count
        documents = documents.offset((page - 1) * per_page).limit(per_page)
        
        render json: {
          documents: documents.map { |doc| document_json(doc) },
          total: total,
          page: page,
          per_page: per_page,
          total_pages: (total.to_f / per_page).ceil
        }
      end

      def show
        return unless authorize_action!('documents', 'read')
        
        render json: { document: document_json(@document) }
      end

      def create
        return unless authorize_action!('documents', 'create')
        # Accept either direct Contact ID or BuyerPortalAccess ID
        contact = @company.contacts.find_by(id: params[:buyer_id])
        
        # Fallback: try BuyerPortalAccess if direct Contact lookup fails
        unless contact
          buyer_portal_access = company_scoped_portal_accesses.find_by(id: params[:buyer_id])
          if buyer_portal_access
            contact = buyer_portal_access.buyer if buyer_portal_access.buyer.is_a?(::Contact)
          end
        end
        
        return render json: { error: 'Contact not found in your company' }, status: :not_found unless contact
        
        @document = PortalDocument.new(
          owner: contact,  # Owner is Contact, not BuyerPortalAccess
          document_name: params[:document_name] || params[:title],
          category: params[:category],
          description: params[:description],
          admin_notes: params[:admin_notes],
          uploaded_by: current_user&.email || 'Admin',
          uploaded_at: Time.current
        )
        
        @document.file.attach(params[:file]) if params[:file].present?
        
        if @document.save
          # Tell the customer it is there. A document sitting unseen in the
          # portal is the same as no document.
          PortalPushService.new_document(document: @document, buyer: contact)

          render json: { document: document_json(@document) }, status: :created
        else
          render json: { errors: @document.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        return unless authorize_action!('documents', 'update')
        
        if @document.update(update_params)
          render json: { document: document_json(@document) }
        else
          render json: { errors: @document.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        return unless authorize_action!('documents', 'delete')
        
        @document.destroy
        head :no_content
      end

      def download
        return unless authorize_action!('documents', 'read')
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
        # Query for Contact-owned documents (new architecture)
        contact_ids = @company.contacts.pluck(:id)
        PortalDocument.where(owner_type: 'Contact', owner_id: contact_ids)
      end

      def update_params
        params.permit(:description, :category, :document_name, :admin_notes)
      end

      def document_json(doc)
        # For Contact-owned documents
        if doc.owner_type == 'Contact'
          contact = doc.owner
          return nil unless contact
          
          buyer_name = "#{contact.first_name} #{contact.last_name}".strip
          buyer_name = contact.email.split('@').first if buyer_name.blank?
          
          return {
            id: doc.id,
            buyer_id: contact.id,
            buyer_name: buyer_name,
            buyer_email: contact.email,
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
            is_buyer_uploaded: doc.uploaded_by == 'buyer',
            status: 'active'
          }
        end
        
        # Legacy: BuyerPortalAccess-owned documents
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
