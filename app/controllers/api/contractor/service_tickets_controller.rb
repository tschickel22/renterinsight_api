# frozen_string_literal: true

module Api
  module Contractor
    class ServiceTicketsController < BaseController
      before_action :set_assignment, only: [:show, :update_status, :add_note, :submit_for_review]

      # GET /api/contractor/service_tickets
      def index
        assignments = ContractorAssignment.where(contractor_id: all_contractor_ids, assignable_type: 'ServiceTicket')
          .includes(:company, :assignable)

        # Stats BEFORE filters
        stats = {
          total: assignments.count,
          assigned: assignments.where(status: 'assigned').count,
          accepted: assignments.where(status: 'accepted').count,
          in_progress: assignments.where(status: 'in_progress').count,
          completed: assignments.where(status: 'completed').count
        }

        # Status filter
        if params[:status].present? && params[:status] != 'all'
          assignments = assignments.where(status: params[:status])
        end

        # Company filter
        assignments = assignments.where(company_id: params[:company_id]) if params[:company_id].present?

        # Search filter
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          assignments = assignments
            .joins("INNER JOIN service_tickets ON service_tickets.id = contractor_assignments.assignable_id")
            .where("service_tickets.title ILIKE ? OR service_tickets.ticket_number ILIKE ? OR CAST(service_tickets.id AS TEXT) ILIKE ?",
                   search_term, search_term, search_term)
        end

        # Sort
        assignments = assignments.order(created_at: :desc)

        # Count AFTER filters
        filtered_count = assignments.count

        # Paginate
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 20).to_i, 100].min
        assignments = assignments.offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: assignments.map { |a| ticket_assignment_json(a) },
          meta: {
            total: filtered_count,
            page: page,
            per_page: per_page,
            total_pages: (filtered_count.to_f / per_page).ceil,
            stats: stats
          }
        }
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
          AssignmentWorkLog.create!(
            contractor_assignment: @assignment,
            contractor_id: current_contractor.id,
            author_type: 'contractor',
            author_name: current_contractor.name,
            note: "Status changed to #{params[:status]}",
            log_type: 'status_change',
            logged_at: Time.current
          )

          render json: ticket_assignment_json(@assignment)
        else
          render json: { errors: @assignment.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/contractor/service-tickets/:id/submit_for_review
      def submit_for_review
        photos = parse_photos(params[:completion_photos])

        @assignment.submit_for_review!(
          summary: params[:completion_summary],
          photos: photos
        )

        AssignmentWorkLog.create!(
          contractor_assignment: @assignment,
          contractor_id: current_contractor.id,
          author_type: 'contractor',
          author_name: current_contractor.name,
          note: "Submitted for review: #{params[:completion_summary].to_s.truncate(200)}",
          log_type: 'completion',
          logged_at: Time.current
        )

        render json: ticket_assignment_json(@assignment)
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/contractor/service-tickets/:id/work_logs
      def work_logs
        assignment = find_ticket_assignment
        return unless assignment

        logs = assignment.work_logs.ordered
        render json: logs.map { |log| work_log_json(log) }
      end

      # POST /api/contractor/service-tickets/:id/work_logs
      def create_work_log
        assignment = find_ticket_assignment
        return unless assignment

        # Convert attachments from ActionController::Parameters to plain hashes for JSONB
        attachments = if params[:attachments].present?
          params[:attachments].map { |a| a.is_a?(ActionController::Parameters) ? a.permit!.to_h : a }
        else
          []
        end

        log = AssignmentWorkLog.new(
          contractor_assignment: assignment,
          contractor_id: current_contractor.id,
          author_type: 'contractor',
          author_name: current_contractor.name,
          note: params[:note],
          log_type: params[:log_type] || 'note',
          attachments: attachments,
          logged_at: Time.current
        )

        if log.save
          render json: work_log_json(log), status: :created
        else
          render json: { errors: log.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/contractor/service-tickets/:id/add_note
      def add_note
        if params[:note].blank?
          return render json: { error: 'Note text is required' }, status: :unprocessable_entity
        end

        timestamp = Time.current.strftime('%Y-%m-%d %H:%M')
        new_note = "[#{timestamp}] Contractor note: #{params[:note]}"
        existing = @assignment.notes.presence || ''
        updated_notes = "#{new_note}\n#{existing}".strip

        if @assignment.update(notes: updated_notes)
          render json: { notes: @assignment.notes }
        else
          render json: { errors: @assignment.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_assignment
        @assignment = ContractorAssignment.where(contractor_id: all_contractor_ids, assignable_type: 'ServiceTicket')
          .find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Service ticket assignment not found' }, status: :not_found
      end

      def find_ticket_assignment
        assignment = ContractorAssignment.where(
          contractor_id: all_contractor_ids,
          assignable_type: 'ServiceTicket'
        ).find(params[:id])
        assignment
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Service ticket assignment not found' }, status: :not_found
        nil
      end

      def work_log_json(log)
        {
          id: log.id,
          contractor_assignment_id: log.contractor_assignment_id,
          contractor_id: log.contractor_id,
          author_type: log.author_type || 'contractor',
          author_name: log.author_name || log.contractor&.name || log.user&.full_name || 'Unknown',
          note: log.note,
          log_type: log.log_type,
          attachments: log.attachments || [],
          logged_at: log.logged_at,
          created_at: log.created_at
        }
      end

      def ticket_assignment_json(assignment, detailed: false)
        ticket = assignment.assignable
        json = {
          id: assignment.id,
          ticket_number: ticket&.ticket_number || "##{ticket&.id}",
          title: ticket&.title,
          description: detailed ? ticket&.description : nil,
          status: assignment.status,
          priority: ticket&.try(:priority),
          assigned_at: assignment.assigned_at || assignment.created_at,
          accepted_at: assignment.accepted_at,
          completed_at: assignment.completed_at,
          scheduled_date: ticket&.try(:scheduled_date),
          notes: assignment.notes,
          ticket_status: ticket&.status,
          company_name: assignment.company&.name,
          company_city: assignment.company&.city,
          company_state: assignment.company&.state,
          company_phone: assignment.company&.phone,
          review_status: assignment.review_status,
          submitted_for_review_at: assignment.submitted_for_review_at,
          completion_summary: assignment.completion_summary,
          completion_photos: assignment.completion_photos || [],
          reviewed_at: assignment.reviewed_at,
          review_notes: assignment.review_notes,
          revision_notes: assignment.revision_notes,
          revision_count: assignment.revision_count || 0,
          reviewed_by_name: assignment.reviewed_by&.full_name
        }

        if detailed && ticket
          json[:property_info] = {
            address: ticket.try(:home_info) || 'N/A'
          }
          json[:parts] = ticket.parts
          json[:labor] = ticket.labor
          json[:line_items] = ticket.try(:line_item_billing)
        end

        json.compact
      end
    end
  end
end
