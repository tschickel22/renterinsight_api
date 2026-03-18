# frozen_string_literal: true

module Api
  module V1
    class ProjectTasksController < ApplicationController
      before_action :set_company_scope
      before_action :set_project
      before_action :set_phase, only: [:index, :create, :reorder]
      before_action :set_task, only: [:show, :update, :destroy, :update_status]

      # GET /api/v1/projects/:project_id/phases/:project_phase_id/tasks
      def index
        return unless authorize_action!('projects', 'read')

        tasks = @phase.tasks.active.ordered.includes(:assigned_to, checklists: :items, dependencies: :depends_on)

        render json: tasks.map { |t| task_json(t) }
      end

      # GET /api/v1/projects/:project_id/tasks/:id
      def show
        return unless authorize_action!('projects', 'read')

        render json: task_json(@task)
      end

      # POST /api/v1/projects/:project_id/phases/:project_phase_id/tasks
      def create
        return unless authorize_action!('projects', 'create')

        task = @phase.tasks.build(task_params)
        task.company = @company
        task.project = @project
        task.position = @phase.tasks.active.count

        if task.save
          render json: task_json(task), status: :created
        else
          render json: { errors: task.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/projects/:project_id/tasks/:id
      def update
        return unless authorize_action!('projects', 'update')

        if @task.update(task_params)
          render json: task_json(@task)
        else
          render json: { errors: @task.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/projects/:project_id/tasks/:id/update_status
      def update_status
        return unless authorize_action!('projects', 'update')

        new_status = params[:status]

        unless %w[pending in_progress completed blocked skipped].include?(new_status)
          return render json: { error: 'Invalid status' }, status: :unprocessable_entity
        end

        if new_status == 'in_progress' && @task.blocked?
          blocking = @task.blocking_tasks.map(&:title)
          return render json: {
            error: "Task is blocked by: #{blocking.join(', ')}"
          }, status: :unprocessable_entity
        end

        updates = { status: new_status }
        updates[:started_at] = Date.current if new_status == 'in_progress' && @task.started_at.nil?
        updates[:completed_at] = Date.current if new_status == 'completed'

        if @task.update(updates)
          ProjectNotificationService.notify_task_completed(@task) if new_status == 'completed'

          render json: task_json(@task)
        else
          render json: { errors: @task.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/projects/:project_id/tasks/:id
      def destroy
        return unless authorize_action!('projects', 'delete')
        @task.update(is_deleted: true)
        render json: { message: 'Task deleted' }
      end

      # POST /api/v1/projects/:project_id/phases/:project_phase_id/tasks/reorder
      def reorder
        return unless authorize_action!('projects', 'update')

        task_ids = params[:task_ids]
        return render(json: { error: 'task_ids required' }, status: :bad_request) unless task_ids.is_a?(Array)

        task_ids.each_with_index do |id, index|
          @phase.tasks.where(id: id).update_all(position: index)
        end

        render json: { message: 'Reordered successfully' }
      end

      private

      def set_project
        @project = @company.projects.find(params[:project_id])
      end

      def set_phase
        phase_id = params[:project_phase_id] || params[:phase_id]
        @phase = @project.project_phases.find(phase_id)
      end

      def set_task
        @task = @project.tasks.active.find(params[:id])
      end

      def task_params
        params.require(:task).permit(
          :title, :description, :status, :priority, :position,
          :due_date, :started_at, :completed_at,
          :estimated_hours, :actual_hours, :estimated_cost, :actual_cost,
          :assigned_to_id, :task_type
        )
      end

      def task_json(task)
        {
          id: task.id,
          projectId: task.project_id,
          phaseId: task.project_phase_id,
          title: task.title,
          description: task.description,
          status: task.status,
          priority: task.priority,
          position: task.position,
          dueDate: task.due_date,
          startedAt: task.started_at,
          completedAt: task.completed_at,
          estimatedHours: task.estimated_hours,
          actualHours: task.actual_hours,
          estimatedCost: task.estimated_cost,
          actualCost: task.actual_cost,
          taskType: task.task_type,
          assignedTo: task.assigned_to ? {
            id: task.assigned_to.id,
            name: "#{task.assigned_to.first_name} #{task.assigned_to.last_name}",
            email: task.assigned_to.email
          } : nil,
          isBlocked: task.blocked?,
          blockingTasks: task.blocking_tasks.map { |bt| { id: bt.id, title: bt.title } },
          checklists: task.checklists.ordered.map { |cl|
            {
              id: cl.id,
              title: cl.title,
              position: cl.position,
              completionPercentage: cl.completion_percentage,
              items: cl.items.ordered.map { |item|
                {
                  id: item.id,
                  title: item.title,
                  completed: item.completed,
                  position: item.position,
                  completedAt: item.completed_at,
                  completedBy: item.completed_by_id
                }
              }
            }
          },
          dependencies: task.dependencies.map { |d|
            {
              id: d.id,
              dependsOnId: d.depends_on_id,
              dependsOnTitle: d.depends_on.title,
              type: d.dependency_type
            }
          },
          createdAt: task.created_at,
          updatedAt: task.updated_at
        }
      end
    end
  end
end
