# frozen_string_literal: true

module Api
  module V1
    class ProjectPhasesController < ApplicationController
      before_action :set_company_scope
      before_action :set_project
      before_action :set_phase

      # PATCH /api/v1/projects/:project_id/phases/:id
      def update
        return unless authorize_action!('deals', 'update')

        if @phase.update(phase_params)
          render json: @phase.as_json(
            only: %i[id name description position status is_required
                     started_at completed_at estimated_start_date estimated_completion_date estimated_days
                     estimated_budget actual_cost
                     visible_to_client notify_client_on_start notify_client_on_complete
                     notes client_notes icon color completed_by_id created_at updated_at],
            methods: [:status_display, :overdue?, :duration_days, :task_progress_percent, :tasks_summary]
          )
        else
          render json: { errors: @phase.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_project
        @project = @company.projects.not_deleted.find(params[:project_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Project not found' }, status: :not_found
      end

      def set_phase
        @phase = @project.project_phases.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Phase not found' }, status: :not_found
      end

      def phase_params
        params.require(:phase).permit(
          :estimated_days, :estimated_start_date, :estimated_completion_date,
          :estimated_budget,
          :notes, :client_notes, :description, :name,
          :visible_to_client, :notify_client_on_start, :notify_client_on_complete
        )
      end
    end
  end
end
