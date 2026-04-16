# frozen_string_literal: true

module Api
  module V1
    class ContractorReviewsController < ApplicationController
      before_action :set_company_scope
      before_action :set_assignment, only: [:show, :approve, :request_revision, :reject]

      # GET /api/v1/contractor-reviews
      def index
        return unless authorize_action!('projects', 'read')

        assignments = ContractorAssignment.where(company_id: @company.id)
          .where.not(review_status: nil)
          .includes(:contractor, :reviewed_by, :assignable)

        # Filter by review_status
        if params[:review_status].present?
          if params[:review_status] == 'reviewed'
            assignments = assignments.where(review_status: %w[approved revision_requested rejected])
          else
            assignments = assignments.where(review_status: params[:review_status])
          end
        end

        # Filter by assignable_type
        if params[:type].present?
          assignable_type = params[:type] == 'task' ? 'ProjectPhaseTask' : 'ServiceTicket'
          assignments = assignments.where(assignable_type: assignable_type)
        end

        # Search by contractor name or summary
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          assignments = assignments.joins(:contractor).where(
            "contractors.name ILIKE ? OR contractors.contact_name ILIKE ? OR contractor_assignments.completion_summary ILIKE ?",
            search_term, search_term, search_term
          )
        end

        # Stats before pagination
        base_scope = ContractorAssignment.where(company_id: @company.id)
        stats = {
          pending: base_scope.where(review_status: 'pending_review').count,
          approved: base_scope.where(review_status: 'approved').count,
          revision_requested: base_scope.where(review_status: 'revision_requested').count,
          rejected: base_scope.where(review_status: 'rejected').count
        }

        # Sort
        sort_by = params[:sort_by] || 'submitted_for_review_at'
        sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
        assignments = assignments.order(sort_by => sort_order)

        # Paginate
        total_count = assignments.count
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 20).to_i, 100].min
        assignments = assignments.offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: assignments.map { |a| review_json(a) },
          meta: {
            total: total_count,
            page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil,
            stats: stats
          }
        }
      end

      # GET /api/v1/contractor-reviews/:id
      def show
        return unless authorize_action!('projects', 'read')

        render json: review_json(@assignment, detailed: true)
      end

      # POST /api/v1/contractor-reviews/:id/approve
      def approve
        return unless authorize_action!('projects', 'update')

        @assignment.approve_review!(
          reviewer: current_user,
          notes: params[:review_notes]
        )

        AssignmentWorkLog.create!(
          contractor_assignment: @assignment,
          user_id: current_user.id,
          author_type: 'dealer',
          author_name: current_user.full_name,
          note: "Approved#{params[:review_notes].present? ? ": #{params[:review_notes]}" : ''}",
          log_type: 'status_change',
          logged_at: Time.current
        )

        render json: { success: true, message: 'Review approved', assignment: review_json(@assignment) }
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/contractor-reviews/:id/request_revision
      def request_revision
        return unless authorize_action!('projects', 'update')

        @assignment.request_revision!(
          reviewer: current_user,
          notes: params[:revision_notes]
        )

        AssignmentWorkLog.create!(
          contractor_assignment: @assignment,
          user_id: current_user.id,
          author_type: 'dealer',
          author_name: current_user.full_name,
          note: "Revision requested: #{params[:revision_notes]}",
          log_type: 'status_change',
          logged_at: Time.current
        )

        render json: { success: true, message: 'Revision requested', assignment: review_json(@assignment) }
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/contractor-reviews/:id/reject
      def reject
        return unless authorize_action!('projects', 'update')

        @assignment.reject_review!(
          reviewer: current_user,
          notes: params[:review_notes]
        )

        AssignmentWorkLog.create!(
          contractor_assignment: @assignment,
          user_id: current_user.id,
          author_type: 'dealer',
          author_name: current_user.full_name,
          note: "Rejected#{params[:review_notes].present? ? ": #{params[:review_notes]}" : ''}",
          log_type: 'status_change',
          logged_at: Time.current
        )

        render json: { success: true, message: 'Review rejected', assignment: review_json(@assignment) }
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def set_assignment
        @assignment = ContractorAssignment.where(company_id: @company.id).find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Review not found' }, status: :not_found
      end

      def review_json(assignment, detailed: false)
        assignable = assignment.assignable
        assignable_info = build_assignable_info(assignment, assignable)

        data = {
          id: assignment.id,
          assignable_type: assignment.assignable_type,
          assignable_id: assignment.assignable_id,
          status: assignment.status,
          review_status: assignment.review_status,
          submitted_for_review_at: assignment.submitted_for_review_at,
          completion_summary: assignment.completion_summary,
          completion_photos: assignment.completion_photos || [],
          reviewed_at: assignment.reviewed_at,
          review_notes: assignment.review_notes,
          revision_notes: assignment.revision_notes,
          revision_count: assignment.revision_count || 0,
          assigned_at: assignment.assigned_at || assignment.created_at,
          completed_at: assignment.completed_at,
          contractor: {
            id: assignment.contractor&.id,
            name: assignment.contractor&.name,
            contact_name: assignment.contractor&.contact_name,
            trade_type: assignment.contractor&.trade_type,
            phone: assignment.contractor&.phone,
            email: assignment.contractor&.email
          },
          reviewed_by: assignment.reviewed_by ? {
            id: assignment.reviewed_by.id,
            name: assignment.reviewed_by.full_name
          } : nil,
          **assignable_info
        }

        if detailed
          data[:work_logs] = assignment.work_logs.ordered.map do |log|
            {
              id: log.id,
              log_type: log.log_type,
              note: log.note,
              author_type: log.author_type,
              author_name: log.author_name,
              attachments: log.attachments || [],
              logged_at: log.logged_at,
              created_at: log.created_at
            }
          end
        end

        data
      end

      def build_assignable_info(assignment, assignable)
        return {} unless assignable

        if assignment.assignable_type == 'ProjectPhaseTask'
          phase = assignable.project_phase
          project = phase&.project
          {
            task_name: assignable.name,
            project_name: project&.name,
            project_id: project&.id,
            phase_name: phase&.name
          }
        elsif assignment.assignable_type == 'ServiceTicket'
          {
            ticket_number: assignable.try(:ticket_number) || "##{assignable.id}",
            ticket_title: assignable.try(:title),
            ticket_id: assignable.id
          }
        else
          {}
        end
      end
    end
  end
end
