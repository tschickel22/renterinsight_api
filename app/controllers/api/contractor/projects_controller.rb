# frozen_string_literal: true

module Api
  module Contractor
    class ProjectsController < BaseController
      # GET /api/contractor/projects
      def index
        # Base: all project IDs where contractor has assignments
        base_project_ids = ContractorAssignment.where(contractor_id: all_contractor_ids, assignable_type: 'ProjectPhaseTask')
          .joins("INNER JOIN project_phase_tasks ON project_phase_tasks.id = contractor_assignments.assignable_id")
          .joins("INNER JOIN project_phases ON project_phases.id = project_phase_tasks.project_phase_id")
          .distinct
          .pluck("project_phases.project_id")

        projects = Project.where(id: base_project_ids, is_deleted: [false, nil])
          .includes(:company, :owner)

        # Stats BEFORE search/status filter (for tiles)
        stats = {
          total: projects.count,
          active: projects.where(status: 'active').count,
          completed: projects.where(status: 'completed').count,
          on_hold: projects.where(status: ['on_hold', 'paused']).count
        }

        # Status filter
        if params[:status].present? && params[:status] != 'all'
          projects = projects.where(status: params[:status])
        end

        # Company filter (multi-dealer)
        if params[:company_id].present?
          projects = projects.where(company_id: params[:company_id])
        end

        # Search filter
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          projects = projects.where(
            "projects.name ILIKE ? OR projects.project_number ILIKE ? OR projects.customer_name ILIKE ?",
            search_term, search_term, search_term
          )
        end

        # Sort
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
        projects = projects.order(sort_by => sort_order)

        # Count AFTER filters (for pagination)
        filtered_count = projects.count

        # Paginate
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 20).to_i, 100].min
        projects = projects.offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: projects.map { |p| project_list_json(p) },
          meta: {
            total: filtered_count,
            page: page,
            per_page: per_page,
            total_pages: (filtered_count.to_f / per_page).ceil,
            stats: stats
          }
        }
      end

      # GET /api/contractor/projects/:id
      def show
        project = Project.where(is_deleted: [false, nil]).find_by(id: params[:id])
        return render(json: { error: 'Project not found' }, status: :not_found) unless project

        # Verify contractor has ProjectPhaseTask assignments on this project
        my_task_ids = ContractorAssignment.where(contractor_id: all_contractor_ids, assignable_type: 'ProjectPhaseTask')
          .joins("INNER JOIN project_phase_tasks ON project_phase_tasks.id = contractor_assignments.assignable_id")
          .joins("INNER JOIN project_phases ON project_phases.id = project_phase_tasks.project_phase_id")
          .where("project_phases.project_id = ?", project.id)
          .pluck(:assignable_id)

        unless my_task_ids.any?
          return render(json: { error: 'Project not found' }, status: :not_found)
        end

        phases = project.project_phases.ordered.includes(project_phase_tasks: { contractor_assignments: :contractor })

        render json: {
          project: project_detail_json(project),
          phases: phases.filter_map { |phase| phase_json(phase, my_task_ids) }
        }
      end

      private

      def project_list_json(project)
        my_assignments = ContractorAssignment.where(
          contractor_id: all_contractor_ids,
          assignable_type: 'ProjectPhaseTask'
        ).joins("INNER JOIN project_phase_tasks ON project_phase_tasks.id = contractor_assignments.assignable_id")
         .joins("INNER JOIN project_phases ON project_phases.id = project_phase_tasks.project_phase_id")
         .where("project_phases.project_id = ?", project.id)

        task_count = my_assignments.count
        completed_count = my_assignments.where(status: 'completed').count
        progress = task_count > 0 ? ((completed_count.to_f / task_count) * 100).round : 0

        {
          id: project.id,
          name: project.name,
          project_number: project.project_number,
          status: project.status,
          delivery_street: project.delivery_street,
          delivery_city: project.delivery_city,
          delivery_state: project.delivery_state,
          delivery_zip: project.delivery_zip,
          home_make: project.home_make,
          home_model: project.home_model,
          customer_name: project.customer_name,
          task_count: task_count,
          completed_count: completed_count,
          progress_percent: progress,
          next_due_date: nil,
          company_name: project.company&.name,
          created_at: project.created_at,
          started_at: project.started_at
        }
      end

      def project_detail_json(project)
        {
          id: project.id,
          name: project.name,
          project_number: project.project_number,
          status: project.status,
          progress_percent: project.progress_percent,
          customer_name: project.customer_name,
          home_make: project.home_make,
          home_model: project.home_model,
          delivery_street: project.delivery_street,
          delivery_city: project.delivery_city,
          delivery_state: project.delivery_state,
          delivery_zip: project.delivery_zip,
          started_at: project.started_at,
          estimated_completion_date: project.estimated_completion_date,
          company_name: project.company&.name,
          customer_phone: project.customer_phone,
          home_serial_number: project.home_serial_number,
          dealer_contact_name: project.owner&.full_name,
          dealer_contact_email: project.owner&.email,
          dealer_contact_phone: project.owner&.phone || project.company&.phone
        }
      end

      def phase_json(phase, my_task_ids)
        my_tasks = phase.project_phase_tasks.select { |t| my_task_ids.include?(t.id) }
        return nil if my_tasks.empty?

        {
          id: phase.id,
          name: phase.name,
          status: phase.status,
          position: phase.position,
          estimated_start_date: phase.estimated_start_date,
          estimated_completion_date: phase.estimated_completion_date,
          task_count: my_tasks.size,
          completed_count: my_tasks.count { |t| t.contractor_assignments.any? { |a| all_contractor_ids.include?(a.contractor_id) && a.status == 'completed' } },
          tasks: my_tasks.map { |task| task_json(task) }
        }
      end

      def task_json(task)
        assignment = task.contractor_assignments.find { |a| all_contractor_ids.include?(a.contractor_id) }

        {
          id: task.id,
          assignment_id: assignment&.id,
          name: task.name,
          status: assignment&.status || task.status,
          assignment_status: assignment&.status,
          task_status: task.status,
          position: task.position,
          is_required: task.is_required,
          estimated_days: task.estimated_days,
          estimated_start_date: task.estimated_start_date,
          estimated_completion_date: task.estimated_completion_date
        }
      end
    end
  end
end
