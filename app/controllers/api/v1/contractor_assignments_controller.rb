# frozen_string_literal: true

module Api
  module V1
    class ContractorAssignmentsController < ApplicationController
      before_action :set_company_scope
      before_action :set_contractor, only: [:index]
      before_action :set_assignment, only: [:update, :destroy]

      # GET /api/v1/contractors/:contractor_id/contractor_assignments
      def index
        return unless authorize_action!('contractors', 'read')

        assignments = @contractor.contractor_assignments.includes(:assignable)

        assignments = assignments.where(status: params[:status]) if params[:status].present?

        render json: assignments.map { |a| assignment_json(a) }
      end

      # POST /api/v1/contractors/:contractor_id/contractor_assignments
      def create
        return unless authorize_action!('contractors', 'create')

        contractor = @company.contractors.not_deleted.find(params[:contractor_id])
        assignable = find_assignable

        unless assignable
          return render json: { error: 'Assignable record not found' }, status: :not_found
        end

        assignment = contractor.contractor_assignments.build(
          assignable: assignable,
          company: @company,
          assigned_by: current_user,
          status: 'assigned',
          assigned_at: Time.current,
          notes: params[:notes]
        )

        if assignment.save
          render json: assignment_json(assignment), status: :created
        else
          render json: { errors: assignment.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/contractors/:contractor_id/contractor_assignments/:id
      def update
        return unless authorize_action!('contractors', 'update')

        update_attrs = { status: params[:status] }

        case params[:status]
        when 'accepted'
          update_attrs[:accepted_at] = Time.current
        when 'completed'
          update_attrs[:completed_at] = Time.current
        end

        update_attrs[:notes] = params[:notes] if params[:notes].present?

        if @assignment.update(update_attrs)
          render json: assignment_json(@assignment)
        else
          render json: { errors: @assignment.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/contractors/:contractor_id/contractor_assignments/:id
      def destroy
        return unless authorize_action!('contractors', 'delete')

        @assignment.destroy
        head :no_content
      end

      private

      def set_contractor
        @contractor = @company.contractors.not_deleted.find(params[:contractor_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Contractor not found' }, status: :not_found
      end

      def set_assignment
        @assignment = @company.contractor_assignments.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Assignment not found' }, status: :not_found
      end

      def find_assignable
        case params[:assignable_type]
        when 'ProjectTask'
          @company.project_tasks.find_by(id: params[:assignable_id])
        when 'ServiceTicket'
          @company.service_tickets.find_by(id: params[:assignable_id])
        end
      end

      def assignment_json(assignment)
        {
          id: assignment.id,
          contractorId: assignment.contractor_id,
          assignableType: assignment.assignable_type,
          assignableId: assignment.assignable_id,
          companyId: assignment.company_id,
          assignedById: assignment.assigned_by_id,
          status: assignment.status,
          assignedAt: assignment.assigned_at,
          acceptedAt: assignment.accepted_at,
          completedAt: assignment.completed_at,
          notes: assignment.notes,
          assignable: assignable_summary(assignment.assignable),
          createdAt: assignment.created_at,
          updatedAt: assignment.updated_at
        }
      end

      def assignable_summary(assignable)
        return nil unless assignable

        case assignable
        when ProjectTask
          { type: 'ProjectTask', id: assignable.id, title: assignable.title, status: assignable.status }
        when ServiceTicket
          { type: 'ServiceTicket', id: assignable.id, title: assignable.title, status: assignable.status }
        else
          { type: assignable.class.name, id: assignable.id }
        end
      end
    end
  end
end
