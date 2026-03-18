# frozen_string_literal: true

module Api
  module Contractor
    class TasksController < BaseController
      before_action :set_assignment, only: [:show, :update_status, :toggle_checklist_item]

      # GET /api/contractor/tasks
      def index
        assignments = current_contractor.contractor_assignments
          .where(assignable_type: 'ProjectTask')
          .includes(assignable: [:project, :project_phase, { checklists: :items }])

        assignments = assignments.where(status: params[:status]) if params[:status].present?
        assignments = assignments.where(company_id: params[:company_id]) if params[:company_id].present?

        render json: assignments.order(created_at: :desc).map { |a| task_assignment_json(a) }
      end

      # GET /api/contractor/tasks/:id
      def show
        render json: task_assignment_json(@assignment, detailed: true)
      end

      # PATCH /api/contractor/tasks/:id/update_status
      def update_status
        unless %w[accepted in_progress completed].include?(params[:status])
          return render json: { error: 'Invalid status' }, status: :unprocessable_entity
        end

        update_attrs = { status: params[:status] }

        case params[:status]
        when 'accepted'
          update_attrs[:accepted_at] = Time.current
        when 'completed'
          update_attrs[:completed_at] = Time.current
        end

        if @assignment.update(update_attrs)
          render json: task_assignment_json(@assignment)
        else
          render json: { errors: @assignment.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/contractor/tasks/:id/toggle_checklist_item
      def toggle_checklist_item
        task = @assignment.assignable

        checklist_item = task.checklists
          .joins(:items)
          .find_by(project_task_checklist_items: { id: params[:checklist_item_id] })
          &.items&.find_by(id: params[:checklist_item_id])

        unless checklist_item
          return render json: { error: 'Checklist item not found' }, status: :not_found
        end

        checklist_item.update!(completed: !checklist_item.completed)

        render json: {
          id: checklist_item.id,
          title: checklist_item.title,
          completed: checklist_item.completed
        }
      end

      private

      def set_assignment
        @assignment = current_contractor.contractor_assignments
          .where(assignable_type: 'ProjectTask')
          .find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Task assignment not found' }, status: :not_found
      end

      def task_assignment_json(assignment, detailed: false)
        task = assignment.assignable
        json = {
          id: assignment.id,
          status: assignment.status,
          assignedAt: assignment.assigned_at,
          acceptedAt: assignment.accepted_at,
          completedAt: assignment.completed_at,
          notes: assignment.notes,
          companyId: assignment.company_id,
          companyName: assignment.company&.name,
          task: {
            id: task&.id,
            title: task&.title,
            status: task&.status,
            priority: task&.try(:priority),
            projectName: task&.project&.name,
            phaseName: task&.project_phase&.name
          }
        }

        if detailed && task
          json[:task][:description] = task.try(:description)
          json[:task][:checklists] = task.checklists.includes(:items).map do |cl|
            {
              id: cl.id,
              title: cl.title,
              items: cl.items.map do |item|
                { id: item.id, title: item.title, completed: item.completed }
              end
            }
          end
        end

        json
      end
    end
  end
end
