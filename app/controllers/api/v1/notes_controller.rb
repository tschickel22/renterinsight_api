module Api
  module V1
    class NotesController < ApplicationController
      before_action :set_note, only: [:update, :destroy]

      # GET /api/v1/notes?entity_type=account&entity_id=1
      def index
        @notes = Note.for_entity(params[:entity_type], params[:entity_id]).recent
        
        render json: {
          notes: @notes.map do |note|
            {
              id: note.id,
              content: note.content,
              entityType: note.entity_type,
              entityId: note.entity_id,
              createdAt: note.created_at,
              updatedAt: note.updated_at,
              createdBy: note.user_id,
              createdByName: note.created_by_name
            }
          end
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

      def set_note
        @note = Note.find(params[:id])
      end

      def note_params
        params.require(:note).permit(:content, :entity_type, :entity_id)
      end

      def note_json(note)
        {
          id: note.id,
          content: note.content,
          entityType: note.entity_type,
          entityId: note.entity_id,
          createdAt: note.created_at,
          updatedAt: note.updated_at,
          createdBy: note.user_id,
          createdByName: note.created_by_name
        }
      end

      def current_user
        # This should be implemented based on your authentication system
        User.first
      end
    end
  end
end
