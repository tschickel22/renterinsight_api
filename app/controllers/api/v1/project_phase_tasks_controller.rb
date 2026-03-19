# frozen_string_literal: true

module Api
  module V1
    class ProjectPhaseTasksController < ApplicationController
      before_action :set_company_scope
      before_action :set_project
      before_action :set_phase
      before_action :set_task, only: %i[update destroy toggle]

      # GET /api/v1/projects/:project_id/phases/:phase_id/tasks
      def index
        return unless authorize_action!('deals', 'read')
        tasks = @phase.project_phase_tasks.ordered.includes(:assigned_to)
        render json: tasks.as_json(
          only: %i[id name position status is_required completed_at completed_by_id
                   assigned_to_id visible_to_client client_actionable client_acknowledged_at client_acknowledged_by
                   created_at updated_at],
          include: { assigned_to: { only: %i[id first_name last_name email] } }
        )
      end

      # POST /api/v1/projects/:project_id/phases/:phase_id/tasks
      def create
        return unless authorize_action!('deals', 'update')
        task = @phase.project_phase_tasks.build(task_params)
        task.company = @company
        task.position = @phase.project_phase_tasks.count
        if task.save
          render json: task.as_json(
            only: %i[id name position status is_required assigned_to_id visible_to_client client_actionable completed_at created_at],
            include: { assigned_to: { only: %i[id first_name last_name email] } }
          ), status: :created
        else
          render json: { errors: task.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/projects/:project_id/phases/:phase_id/tasks/:id
      def update
        return unless authorize_action!('deals', 'update')
        if @task.update(task_params)
          render json: @task.as_json(
            only: %i[id name position status is_required assigned_to_id visible_to_client client_actionable completed_at updated_at],
            include: { assigned_to: { only: %i[id first_name last_name email] } }
          )
        else
          render json: { errors: @task.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/projects/:project_id/phases/:phase_id/tasks/:id
      def destroy
        return unless authorize_action!('deals', 'update')
        @task.destroy!
        render json: { message: 'Task deleted' }
      end

      # POST /api/v1/projects/:project_id/phases/:phase_id/tasks/:id/toggle
      def toggle
        return unless authorize_action!('deals', 'update')

        if @task.status == 'completed'
          @task.reopen!
        else
          @task.complete!(by: current_user)
          # Auto-advance phase to in_progress if it was not_started
          if @phase.status == 'not_started'
            @phase.update!(status: 'in_progress', started_at: @phase.started_at || Time.current)
            @project.recalc_current_phase!
            @project.update_progress_cache!
            @project.save!
          end
        end

        render json: {
          task: @task.as_json(only: %i[id name status completed_at]),
          phase: @phase.reload.as_json(
            only: %i[id status started_at],
            methods: %i[task_progress_percent tasks_summary]
          ),
          project: @project.reload.as_json(
            only: %i[id progress_percent completed_phase_count current_phase_id]
          )
        }
      end

      private

      def set_project
        @project = @company.projects.not_deleted.find(params[:project_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Project not found' }, status: :not_found
      end

      def set_phase
        # Rails nested resources use :phase_id for the outer resource param
        # Fall back to checking all likely param names
        phase_id = params[:phase_id] || params[:phase_id.to_s]
        @phase = @project.project_phases.find_by(id: phase_id)
        unless @phase
          Rails.logger.error "[ProjectPhaseTasksController] Phase not found: project_id=#{params[:project_id]} phase_id=#{phase_id} params=#{params.to_unsafe_h.inspect}"
          render json: { error: 'Phase not found' }, status: :not_found
        end
      end

      def set_task
        @task = @phase.project_phase_tasks.find_by(id: params[:id])
        unless @task
          render json: { error: 'Task not found' }, status: :not_found
        end
      end

      def task_params
        params.require(:task).permit(:name, :position, :is_required, :assigned_to_id, :visible_to_client, :client_actionable,
                                     :estimated_days, :estimated_start_date, :estimated_completion_date)
      end
    end
  end
end
