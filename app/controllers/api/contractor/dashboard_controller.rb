# frozen_string_literal: true

module Api
  module Contractor
    class DashboardController < BaseController
      # GET /api/contractor/dashboard
      def index
        all_assignments = ContractorAssignment.where(contractor_id: all_contractor_ids)
          .includes(:assignable, :company)

        status_counts = all_assignments.group(:status).count

        companies = all_contractors.includes(:company).map(&:company).compact.uniq.map do |c|
          { id: c.id, name: c.name, city: c.city, state: c.state, phone: c.phone }
        end

        # Filterable recent assignments
        recent = all_assignments

        # Status filter
        if params[:status].present? && params[:status] != 'all'
          recent = recent.where(status: params[:status])
        end

        # Company filter
        if params[:company_id].present?
          recent = recent.where(company_id: params[:company_id])
        end

        # Search filter
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          task_ids = recent.where(assignable_type: 'ProjectPhaseTask')
            .joins("INNER JOIN project_phase_tasks ON project_phase_tasks.id = contractor_assignments.assignable_id")
            .joins("INNER JOIN project_phases ON project_phases.id = project_phase_tasks.project_phase_id")
            .joins("INNER JOIN projects ON projects.id = project_phases.project_id")
            .where("project_phase_tasks.name ILIKE ? OR projects.name ILIKE ?", search_term, search_term)
            .pluck(:id)

          ticket_ids = recent.where(assignable_type: 'ServiceTicket')
            .joins("INNER JOIN service_tickets ON service_tickets.id = contractor_assignments.assignable_id")
            .where("service_tickets.title ILIKE ? OR service_tickets.ticket_number ILIKE ?", search_term, search_term)
            .pluck(:id)

          recent = recent.where(id: task_ids + ticket_ids)
        end

        # Count + paginate
        filtered_count = recent.count
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 20).to_i, 100].min
        recent = recent.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

        render json: {
          stats: {
            total_assignments: all_assignments.count,
            assigned: status_counts['assigned'] || 0,
            accepted: status_counts['accepted'] || 0,
            in_progress: status_counts['in_progress'] || 0,
            completed: status_counts['completed'] || 0
          },
          companies: companies,
          recent_assignments: recent.map { |a| portal_assignment_json(a) },
          meta: {
            total: filtered_count,
            page: page,
            per_page: per_page,
            total_pages: (filtered_count.to_f / per_page).ceil
          }
        }
      end

      private

      def portal_assignment_json(assignment)
        assignable = assignment.assignable
        company = assignment.company

        is_task = assignment.assignable_type == 'ProjectPhaseTask'
        task_name = assignable.try(:name) || assignable.try(:title) || 'Untitled'
        project_name = if is_task
                         assignable&.project_phase&.project&.name
                       else
                         'Service Ticket'
                       end

        {
          id: assignment.id,
          name: task_name,
          project_name: project_name,
          status: assignment.status,
          assigned_at: assignment.assigned_at || assignment.created_at,
          type: is_task ? 'task' : 'service_ticket',
          company_name: company&.name,
          company_city: company&.city,
          company_state: company&.state,
          company_phone: company&.phone
        }
      end
    end
  end
end
