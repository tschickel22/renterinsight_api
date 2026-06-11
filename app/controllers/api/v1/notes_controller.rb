# frozen_string_literal: true

module Api
  module V1
    class NotesController < ApplicationController
      include RbacAuthorization
      rbac_resource :crm

      before_action :set_company
      before_action :validate_entity_access, only: [:index, :create]
      before_action :set_note, only: [:update, :destroy]

      # GET /api/v1/notes?entity_type=account&entity_id=1&category=customer
      def index
        @notes = Note.for_entity(params[:entity_type], params[:entity_id]).recent
        @notes = @notes.where(category: params[:category]) if params[:category].present?

        render json: {
          notes: @notes.map { |note| note_json(note) }
        }
      end

      # POST /api/v1/notes
      def create
        @note = Note.new(note_params)
        @note.user_id ||= current_user&.id

        if @note.save
          render json: note_json(@note), status: :created
        else
          render json: { errors: @note.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/notes/:id
      def update
        if @note.update(note_params)
          render json: note_json(@note)
        else
          render json: { errors: @note.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/notes/:id
      def destroy
        @note.destroy
        head :no_content
      end

      private

      def set_company
        @company = ::Company.find_by(id: current_company_id)
        unless @company
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
      end

      # TENANT ISOLATION: Validate that the entity belongs to the current company
      def validate_entity_access
        entity_type = params[:entity_type] || params.dig(:note, :entity_type)
        entity_id = params[:entity_id] || params.dig(:note, :entity_id)

        unless entity_type.present? && entity_id.present?
          render json: { error: 'entity_type and entity_id are required' }, status: :unprocessable_entity
          return
        end

        # Verify the entity belongs to the current company
        unless entity_belongs_to_company?(entity_type, entity_id)
          Rails.logger.warn "[NotesController] Entity access denied: #{entity_type}##{entity_id} not in company #{@company.id}"
          render json: { error: 'Entity not found or access denied' }, status: :not_found
          return
        end
      end

      def set_note
        @note = Note.find_by(id: params[:id])
        
        unless @note
          render json: { error: 'Note not found' }, status: :not_found
          return
        end

        # TENANT ISOLATION: Verify the note's entity belongs to this company
        unless entity_belongs_to_company?(@note.entity_type, @note.entity_id)
          Rails.logger.warn "[NotesController] Note access denied: Note##{params[:id]} entity not in company #{@company.id}"
          render json: { error: 'Note not found or access denied' }, status: :not_found
          return
        end
      end

      # Check if the entity belongs to the current company
      def entity_belongs_to_company?(entity_type, entity_id)
        case entity_type.to_s.downcase
        when 'account'
          @company.accounts.exists?(id: entity_id)
        when 'contact'
          @company.contacts.exists?(id: entity_id)
        when 'vehicle'
          @company.vehicles.exists?(id: entity_id)
        when 'lead'
          Lead.where(company_id: @company.id).exists?(id: entity_id) if defined?(Lead)
        when 'deal'
          Deal.where(company_id: @company.id).exists?(id: entity_id) if defined?(Deal)
        when 'quote'
          @company.quotes.exists?(id: entity_id) if @company.respond_to?(:quotes)
        when 'service_ticket'
          @company.service_tickets.exists?(id: entity_id) if @company.respond_to?(:service_tickets)
        when 'land_parcel'
          @company.land_parcels.exists?(id: entity_id) if @company.respond_to?(:land_parcels)
        when 'listing'
          @company.listings.exists?(id: entity_id) if @company.respond_to?(:listings)
        when 'brochure'
          @company.brochures.exists?(id: entity_id) if @company.respond_to?(:brochures)
        else
          # Unknown entity type - deny access by default
          Rails.logger.warn "[NotesController] Unknown entity type: #{entity_type}"
          false
        end
      end

      def note_params
        params.require(:note).permit(:content, :entity_type, :entity_id, :category)
      end

      def note_json(note)
        {
          id: note.id,
          content: note.content,
          entityType: note.entity_type,
          entityId: note.entity_id,
          category: note.category,
          authorType: note.author_type,
          createdAt: note.created_at,
          updatedAt: note.updated_at,
          createdBy: note.user_id,
          createdByName: note.created_by_name
        }
      end
    end
  end
end
