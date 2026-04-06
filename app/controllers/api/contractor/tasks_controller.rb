# frozen_string_literal: true

module Api
  module Contractor
    class TasksController < BaseController
      before_action :set_assignment, only: [:show, :update_status, :toggle_checklist_item, :add_note, :submit_for_review]

      # GET /api/contractor/tasks
      def index
        assignments = ContractorAssignment.where(contractor_id: all_contractor_ids, assignable_type: 'ProjectPhaseTask')
          .includes(:company, assignable: { project_phase: :project })

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
            .joins("INNER JOIN project_phase_tasks ON project_phase_tasks.id = contractor_assignments.assignable_id")
            .joins("INNER JOIN project_phases ON project_phases.id = project_phase_tasks.project_phase_id")
            .joins("INNER JOIN projects ON projects.id = project_phases.project_id")
            .where("project_phase_tasks.name ILIKE ? OR projects.name ILIKE ? OR projects.customer_name ILIKE ?",
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
          items: assignments.map { |a| task_assignment_json(a) },
          meta: {
            total: filtered_count,
            page: page,
            per_page: per_page,
            total_pages: (filtered_count.to_f / per_page).ceil,
            stats: stats
          }
        }
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
          AssignmentWorkLog.create!(
            contractor_assignment: @assignment,
            contractor_id: current_contractor.id,
            author_type: 'contractor',
            author_name: current_contractor.name,
            note: "Status changed to #{params[:status]}",
            log_type: 'status_change',
            logged_at: Time.current
          )

          # Sync status to the ProjectPhaseTask so project progress updates
          task = @assignment.assignable
          if task.present?
            case params[:status]
            when 'in_progress'
              task.update(status: 'in_progress') unless task.status == 'completed'
            when 'completed'
              task.update(status: 'completed')
            end
          end

          render json: task_assignment_json(@assignment)
        else
          render json: { errors: @assignment.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/contractor/tasks/:id/submit_for_review
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

        render json: task_assignment_json(@assignment)
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/contractor/tasks/:id/add_note
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

      # PATCH /api/contractor/tasks/:id/toggle_checklist_item
      # NOTE: ProjectPhaseTask does not have checklists — this is a no-op placeholder
      def toggle_checklist_item
        render json: { error: 'Checklists are not available for this task type' }, status: :not_found
      end

      # GET /api/contractor/tasks/:id/work_logs
      def work_logs
        assignment = find_task_assignment
        return unless assignment

        logs = assignment.work_logs.ordered
        render json: logs.map { |log| work_log_json(log) }
      end

      # POST /api/contractor/tasks/:id/work_logs
      def create_work_log
        assignment = find_task_assignment
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

      private

      def set_assignment
        @assignment = ContractorAssignment.where(contractor_id: all_contractor_ids, assignable_type: 'ProjectPhaseTask')
          .find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Task assignment not found' }, status: :not_found
      end

      def find_task_assignment
        assignment = ContractorAssignment.where(
          contractor_id: all_contractor_ids,
          assignable_type: 'ProjectPhaseTask'
        ).find(params[:id])
        assignment
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Task assignment not found' }, status: :not_found
        nil
      end

      def task_assignment_json(assignment, detailed: false)
        task = assignment.assignable
        phase = task&.project_phase
        project = phase&.project
        json = {
          id: assignment.id,
          name: task&.name,
          project_name: project&.name,
          phase_name: phase&.name,
          project_id: project&.id,
          status: assignment.status,
          task_status: task&.status,
          position: task&.position,
          is_required: task&.is_required,
          estimated_days: task&.estimated_days,
          estimated_start_date: task&.estimated_start_date,
          estimated_completion_date: task&.estimated_completion_date,
          assigned_at: assignment.assigned_at || assignment.created_at,
          accepted_at: assignment.accepted_at,
          completed_at: assignment.completed_at,
          notes: assignment.notes,
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

        if detailed && task
          json[:job_info] = {
            project_name: project&.name,
            project_number: project&.project_number,
            status: project&.status,
            delivery_street: project&.delivery_street,
            delivery_city: project&.delivery_city,
            delivery_state: project&.delivery_state,
            delivery_zip: project&.delivery_zip,
            home_make: project&.home_make,
            home_model: project&.home_model,
            home_serial_number: project&.home_serial_number,
            customer_name: project&.customer_name,
            customer_phone: project&.customer_phone,
            dealer_contact_name: project&.owner&.full_name,
            dealer_contact_email: project&.owner&.email,
            dealer_contact_phone: project&.owner&.phone || assignment.company&.phone,
            estimated_days: task.estimated_days,
            estimated_start_date: task.estimated_start_date,
            estimated_completion_date: task.estimated_completion_date
          }

          json[:phase_info] = {
            name: phase&.name,
            status: phase&.status,
            position: phase&.position
          }
        end

        json.compact
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
    end
  end
end
