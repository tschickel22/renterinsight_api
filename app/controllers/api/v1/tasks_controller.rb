module Api
  module V1
    class TasksController < ApplicationController
      include RbacAuthorization
      rbac_resource :tasks
      
      before_action :set_company_scope
      before_action :set_task, only: [:show, :update, :destroy, :complete, :reopen]
      
      # GET /api/v1/tasks
      def index
        return unless authorize_action!('tasks', 'read')
        
        tasks = @company.tasks
          .includes(:assigned_to, :taskable)
          .for_current_location
        
        # Apply RBAC location filtering for location-tier users
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          tasks = location_ids.any? ? tasks.where(location_id: location_ids) : tasks.none
        end
        
        # Optional filters from query params
        tasks = tasks.where(status: params[:status]) if params[:status].present?
        tasks = tasks.where(priority: params[:priority]) if params[:priority].present?
        tasks = tasks.where(task_module: params[:module]) if params[:module].present?
        tasks = tasks.where(assigned_to_id: params[:assigned_to_id]) if params[:assigned_to_id].present?
        tasks = tasks.overdue if params[:overdue] == 'true'
        tasks = tasks.active if params[:active] == 'true'
        
        # Order by priority and due date
        tasks = tasks.by_priority_and_date
        
        render json: tasks.as_json(
          include: {
            assigned_to: { only: [:id, :name, :email] },
            taskable: { only: [:id, :type] }
          },
          methods: [:overdue?]
        )
      end
      
      # GET /api/v1/tasks/:id
      def show
        return unless authorize_action!('tasks', 'read')
        
        render json: @task.as_json(
          include: {
            assigned_to: { only: [:id, :name, :email] },
            taskable: { only: [:id, :type] }
          },
          methods: [:overdue?]
        )
      end
      
      # POST /api/v1/tasks
      def create
        return unless authorize_action!('tasks', 'create')
        
        task = @company.tasks.build(task_params)
        
        # Auto-assign location if not provided
        task.location_id ||= Current.location_id if Current.location_id.present?
        
        # RBAC fallback for location-tier users
        if task.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          task.location_id = location_ids.first if location_ids.any?
        end
        
        # Set audit fields
        task.created_by = current_user.name
        task.source_type ||= 'user_created'
        
        if task.save
          render json: task.as_json(
            include: { assigned_to: { only: [:id, :name, :email] } },
            methods: [:overdue?]
          ), status: :created
        else
          render json: { errors: task.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH /api/v1/tasks/:id
      def update
        return unless authorize_action!('tasks', 'update')
        
        # Set audit fields
        update_params = task_params.merge(updated_by: current_user.name)
        
        if @task.update(update_params)
          render json: @task.as_json(
            include: { assigned_to: { only: [:id, :name, :email] } },
            methods: [:overdue?]
          )
        else
          render json: { errors: @task.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/tasks/:id
      def destroy
        return unless authorize_action!('tasks', 'delete')
        
        @task.destroy
        head :no_content
      end
      
      # POST /api/v1/tasks/:id/complete
      def complete
        return unless authorize_action!('tasks', 'update')
        
        if @task.complete!
          render json: @task.as_json(
            include: { assigned_to: { only: [:id, :name, :email] } },
            methods: [:overdue?]
          )
        else
          render json: { errors: @task.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/tasks/:id/reopen
      def reopen
        return unless authorize_action!('tasks', 'update')
        
        if @task.reopen!
          render json: @task.as_json(
            include: { assigned_to: { only: [:id, :name, :email] } },
            methods: [:overdue?]
          )
        else
          render json: { errors: @task.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # GET /api/v1/tasks/stats
      def stats
        return unless authorize_action!('tasks', 'read')
        
        base_tasks = @company.tasks.for_current_location
        
        # Apply RBAC location filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          base_tasks = location_ids.any? ? base_tasks.where(location_id: location_ids) : base_tasks.none
        end
        
        render json: {
          total: base_tasks.count,
          overdue: base_tasks.overdue.count,
          pending: base_tasks.status_pending.count,
          in_progress: base_tasks.status_in_progress.count,
          completed: base_tasks.status_completed.count,
          by_priority: {
            low: base_tasks.priority_low.count,
            medium: base_tasks.priority_medium.count,
            high: base_tasks.priority_high.count,
            urgent: base_tasks.priority_urgent.count
          },
          by_module: base_tasks.group(:task_module).count
        }
      end
      
      private
      
      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [TasksController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [TasksController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [TasksController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [TasksController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end
      
      def set_task
        @task = @company.tasks.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Task not found or access denied' }, status: :not_found
      end
      
      def task_params
        params.require(:task).permit(
          :title,
          :description,
          :status,
          :priority,
          :task_module,
          :assigned_to_id,
          :due_date,
          :taskable_type,
          :taskable_id,
          :source_type,
          :source_id,
          :link,
          :location_id,
          tags: [],
          custom_fields: {}
        )
      end
      
      def permission_service
        @permission_service ||= PermissionService.new(current_user)
      end
    end
  end
end
