# frozen_string_literal: true

module Api
  module V1
    class PhaseTaskWorkLogsController < ApplicationController
      before_action :set_company_scope
      before_action :set_project
      before_action :set_phase
      before_action :set_phase_task

      # GET /api/v1/projects/:project_id/phases/:phase_id/phase_tasks/:id/work_logs
      def index
        return unless authorize_action!('projects', 'read')

        assignment_ids = @phase_task.contractor_assignments.pluck(:id)
        logs = AssignmentWorkLog.where(contractor_assignment_id: assignment_ids)
          .includes(:contractor, :user)
          .order(logged_at: :desc, created_at: :desc)

        render json: logs.map { |log| work_log_json(log) }
      end

      # POST /api/v1/projects/:project_id/phases/:phase_id/phase_tasks/:id/work_logs
      def create
        return unless authorize_action!('projects', 'update')

        assignments = @phase_task.contractor_assignments

        if assignments.empty?
          return render json: { error: 'No contractor assigned to this task' }, status: :unprocessable_entity
        end

        assignment = if params[:contractor_assignment_id].present?
          assignments.find_by(id: params[:contractor_assignment_id])
        else
          assignments.first
        end

        unless assignment
          return render json: { error: 'Contractor assignment not found' }, status: :not_found
        end

        attachments = if params[:attachments].present?
          params[:attachments].map { |a| a.is_a?(ActionController::Parameters) ? a.permit!.to_h : a }
        else
          []
        end

        log = AssignmentWorkLog.new(
          contractor_assignment: assignment,
          user_id: current_user.id,
          author_type: 'dealer',
          author_name: current_user.full_name.presence || current_user.email,
          note: params[:note],
          log_type: params[:log_type] || 'note',
          attachments: attachments,
          logged_at: Time.current
        )

        if log.save
          render json: work_log_json(log), status: :created
        else
          render json: { errors: log.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_project
        @project = @company.projects.find(params[:project_id])
      end

      def set_phase
        @phase = @project.project_phases.find(params[:phase_id])
      end

      def set_phase_task
        @phase_task = @phase.project_phase_tasks.find(params[:id])
      end

      def work_log_json(log)
        {
          id: log.id,
          contractor_assignment_id: log.contractor_assignment_id,
          author_type: log.author_type || 'contractor',
          author_name: log.author_name || log.contractor&.name || log.user&.full_name || 'Unknown',
          note: log.note,
          log_type: log.log_type,
          attachments: log.attachments || [],
          logged_at: log.logged_at,
          created_at: log.created_at
        }
      end
    end
  end
end
