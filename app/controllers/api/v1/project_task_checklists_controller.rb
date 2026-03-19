# frozen_string_literal: true

module Api
  module V1
    class ProjectTaskChecklistsController < ApplicationController
      before_action :set_company_scope
      before_action :set_task
      before_action :set_checklist, only: [:update, :destroy]

      # POST /api/v1/projects/:project_id/tasks/:task_id/checklists
      def create
        return unless authorize_action!('projects', 'create')

        checklist = @task.checklists.build(checklist_params)
        checklist.position = @task.checklists.count

        if params[:checklist][:items].present?
          params[:checklist][:items].each_with_index do |item_title, idx|
            checklist.items.build(title: item_title, position: idx)
          end
        end

        if checklist.save
          render json: checklist_json(checklist), status: :created
        else
          render json: { errors: checklist.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/projects/:project_id/tasks/:task_id/checklists/:id
      def update
        return unless authorize_action!('projects', 'update')

        if @checklist.update(checklist_params)
          render json: checklist_json(@checklist)
        else
          render json: { errors: @checklist.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/projects/:project_id/tasks/:task_id/checklists/:id
      def destroy
        return unless authorize_action!('projects', 'delete')
        @checklist.destroy
        render json: { message: 'Checklist deleted' }
      end

      # POST /api/v1/projects/:project_id/tasks/:task_id/checklists/:checklist_id/items
      def add_item
        return unless authorize_action!('projects', 'create')

        checklist = @task.checklists.find(params[:checklist_id])
        item = checklist.items.build(
          title: params[:title],
          position: checklist.items.count
        )

        if item.save
          render json: item_json(item), status: :created
        else
          render json: { errors: item.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/projects/:project_id/tasks/:task_id/checklist_items/:id/toggle
      def toggle_item
        return unless authorize_action!('projects', 'update')

        item = ProjectTaskChecklistItem.joins(project_task_checklist: :project_task)
          .where(project_tasks: { project_id: params[:project_id], company_id: @company.id })
          .find(params[:id])

        item.completed_by = current_user unless item.completed?
        item.toggle!

        render json: item_json(item)
      end

      # DELETE /api/v1/projects/:project_id/tasks/:task_id/checklist_items/:id
      def delete_item
        return unless authorize_action!('projects', 'delete')

        item = ProjectTaskChecklistItem.joins(project_task_checklist: :project_task)
          .where(project_tasks: { project_id: params[:project_id], company_id: @company.id })
          .find(params[:id])

        item.destroy
        render json: { message: 'Item deleted' }
      end

      private

      def set_task
        project = @company.projects.find(params[:project_id])
        task_id = params[:task_id] || params[:project_task_detail_id]
        @task = project.tasks.active.find(task_id)
      end

      def set_checklist
        @checklist = @task.checklists.find(params[:id])
      end

      def checklist_params
        params.require(:checklist).permit(:title, :position)
      end

      def checklist_json(checklist)
        {
          id: checklist.id,
          title: checklist.title,
          position: checklist.position,
          completionPercentage: checklist.completion_percentage,
          items: checklist.items.ordered.map { |i| item_json(i) }
        }
      end

      def item_json(item)
        {
          id: item.id,
          title: item.title,
          completed: item.completed,
          position: item.position,
          completedAt: item.completed_at,
          completedBy: item.completed_by_id
        }
      end
    end
  end
end
