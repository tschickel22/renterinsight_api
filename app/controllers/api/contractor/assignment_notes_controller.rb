# frozen_string_literal: true

module Api
  module Contractor
    class AssignmentNotesController < BaseController
      # PATCH /api/contractor/tasks/:id/add_note
      def add_task_note
        assignment = current_contractor.contractor_assignments
          .where(assignable_type: 'ProjectTask')
          .find(params[:id])

        append_note(assignment)
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Task assignment not found' }, status: :not_found
      end

      # PATCH /api/contractor/service-tickets/:id/add_note
      def add_ticket_note
        assignment = current_contractor.contractor_assignments
          .where(assignable_type: 'ServiceTicket')
          .find(params[:id])

        append_note(assignment)
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Service ticket assignment not found' }, status: :not_found
      end

      private

      def append_note(assignment)
        if params[:note].blank?
          return render json: { error: 'Note text is required' }, status: :unprocessable_entity
        end

        timestamp = Time.current.strftime('%Y-%m-%d %H:%M')
        new_note = "[#{timestamp}] Contractor note: #{params[:note]}"
        existing = assignment.notes.presence || ''
        updated_notes = "#{new_note}\n#{existing}".strip

        if assignment.update(notes: updated_notes)
          render json: { notes: assignment.notes }
        else
          render json: { errors: assignment.errors.full_messages }, status: :unprocessable_entity
        end
      end
    end
  end
end
