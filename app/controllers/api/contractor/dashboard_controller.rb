# frozen_string_literal: true

module Api
  module Contractor
    class DashboardController < BaseController
      # GET /api/contractor/dashboard
      def index
        assignments = current_contractor.contractor_assignments.includes(:assignable, :company)

        status_counts = assignments.group(:status).count

        render json: {
          summary: {
            total: assignments.count,
            assigned: status_counts['assigned'] || 0,
            accepted: status_counts['accepted'] || 0,
            in_progress: status_counts['in_progress'] || 0,
            completed: status_counts['completed'] || 0,
            declined: status_counts['declined'] || 0
          },
          companies: assignments.map(&:company).uniq.map { |c| { id: c.id, name: c.name } },
          recent_assignments: assignments.order(created_at: :desc).limit(10).map { |a| portal_assignment_json(a) }
        }
      end

      private

      def portal_assignment_json(assignment)
        {
          id: assignment.id,
          assignableType: assignment.assignable_type,
          assignableId: assignment.assignable_id,
          companyId: assignment.company_id,
          companyName: assignment.company&.name,
          status: assignment.status,
          assignedAt: assignment.assigned_at,
          title: assignment.assignable&.try(:title),
          notes: assignment.notes
        }
      end
    end
  end
end
