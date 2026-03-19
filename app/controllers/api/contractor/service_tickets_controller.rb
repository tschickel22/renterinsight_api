# frozen_string_literal: true

module Api
  module Contractor
    class ServiceTicketsController < BaseController
      before_action :set_assignment, only: [:show, :update_status]

      # GET /api/contractor/service_tickets
      def index
        assignments = current_contractor.contractor_assignments
          .where(assignable_type: 'ServiceTicket')
          .includes(:assignable)

        assignments = assignments.where(status: params[:status]) if params[:status].present?
        assignments = assignments.where(company_id: params[:company_id]) if params[:company_id].present?

        render json: assignments.order(created_at: :desc).map { |a| ticket_assignment_json(a) }
      end

      # GET /api/contractor/service_tickets/:id
      def show
        render json: ticket_assignment_json(@assignment, detailed: true)
      end

      # PATCH /api/contractor/service_tickets/:id/update_status
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
          render json: ticket_assignment_json(@assignment)
        else
          render json: { errors: @assignment.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_assignment
        @assignment = current_contractor.contractor_assignments
          .where(assignable_type: 'ServiceTicket')
          .find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Service ticket assignment not found' }, status: :not_found
      end

      def ticket_assignment_json(assignment, detailed: false)
        ticket = assignment.assignable
        json = {
          id: assignment.id,
          status: assignment.status,
          assignedAt: assignment.assigned_at,
          acceptedAt: assignment.accepted_at,
          completedAt: assignment.completed_at,
          notes: assignment.notes,
          companyId: assignment.company_id,
          companyName: assignment.company&.name,
          ticket: {
            id: ticket&.id,
            title: ticket&.title,
            status: ticket&.status,
            priority: ticket&.try(:priority),
            scheduledDate: ticket&.try(:scheduled_date)
          }
        }

        if detailed && ticket
          json[:ticket][:description] = ticket.try(:description)
          json[:ticket][:parts] = ticket.try(:parts)
          json[:ticket][:labor] = ticket.try(:labor)
        end

        json
      end
    end
  end
end
