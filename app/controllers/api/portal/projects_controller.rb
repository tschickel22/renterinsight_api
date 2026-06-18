# frozen_string_literal: true

module Api
  module Portal
    class ProjectsController < ApplicationController
      skip_before_action :authenticate
      before_action :authenticate_portal_buyer!

      # GET /api/portal/projects
      def index
        return render(json: { success: true, data: [] }) unless current_portal_buyer&.buyer

        projects = buyer_projects.order(created_at: :desc)

        render json: {
          success: true,
          data: projects.map { |project| serialize_project(project) }
        }
      end

      # GET /api/portal/projects/pending_approvals
      # Cross-project list of completed contractor work awaiting THIS buyer's
      # review, for the dashboard tile + count. Mirrors the public progress
      # page's pending_reviews, but scoped to the logged-in buyer's projects.
      def pending_approvals
        return render(json: { success: true, count: 0, data: [] }) unless current_portal_buyer&.buyer

        projects = buyer_projects.index_by(&:id)
        return render(json: { success: true, count: 0, data: [] }) if projects.empty?

        phases = ProjectPhase.where(project_id: projects.keys, visible_to_client: true).index_by(&:id)
        tasks  = ProjectPhaseTask.where(project_phase_id: phases.keys, visible_to_client: true).index_by(&:id)
        return render(json: { success: true, count: 0, data: [] }) if tasks.empty?

        assignments = ContractorAssignment
                        .where(assignable_type: 'ProjectPhaseTask', assignable_id: tasks.keys)
                        .where(client_review_required: true,
                               client_review_status: ContractorAssignment::CLIENT_REVIEW_PENDING)
                        .includes(:contractor)
                        .order(submitted_for_review_at: :desc)

        data = assignments.map do |assignment|
          task    = tasks[assignment.assignable_id]
          phase   = phases[task.project_phase_id]
          project = projects[phase.project_id]
          serialize_pending_approval(assignment, task, phase, project)
        end

        render json: { success: true, count: data.size, data: data }
      end

      # POST /api/portal/projects/:id/reviews/:assignment_id/approve
      def approve
        assignment = load_buyer_review_assignment
        return unless assignment

        assignment.client_approve!(notes: params[:notes])
        render json: { success: true, message: 'Thank you — your approval has been recorded.' }
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/portal/projects/:id/reviews/:assignment_id/request_revision
      def request_revision
        assignment = load_buyer_review_assignment
        return unless assignment

        if params[:notes].blank?
          return render json: { error: 'Please tell us what needs to change.' }, status: :unprocessable_entity
        end

        assignment.client_request_revision!(notes: params[:notes])
        render json: { success: true, message: 'Thanks — we have asked the contractor to make the changes.' }
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/portal/projects/:id/reviews/:assignment_id/reject
      def reject
        assignment = load_buyer_review_assignment
        return unless assignment

        assignment.client_reject!(notes: params[:notes])
        render json: { success: true, message: 'Thanks — we have let the team know.' }
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/portal/projects/:id
      def show
        project = find_portal_project(params[:id])
        return render(json: { error: 'Project not found' }, status: :not_found) unless project

        phases = project.project_phases.where(visible_to_client: true).order(:position)
        pending_by_task = pending_reviews_by_task(phases)   # task_id => ContractorAssignment

        render json: {
          success: true,
          data: serialize_project(project),
          phases: phases.map { |phase| serialize_phase(phase, project, pending_by_task) }
        }
      end

      # POST /api/portal/projects/:id/acknowledge_task
      # Body: { phase_id:, task_id: }
      def acknowledge_task
        project = find_portal_project(params[:id])
        return render(json: { error: 'Project not found' }, status: :not_found) unless project

        phase = project.project_phases.find_by(id: params[:phase_id], visible_to_client: true)
        return render(json: { error: 'Phase not found' }, status: :not_found) unless phase

        task = phase.project_phase_tasks.find_by(id: params[:task_id], visible_to_client: true, client_actionable: true)
        return render(json: { error: 'Task not found or not actionable' }, status: :not_found) unless task

        if task.client_acknowledged_at.present?
          return render(json: { error: 'Already acknowledged' }, status: :unprocessable_entity)
        end

        buyer = current_portal_buyer&.buyer
        buyer_name = buyer.respond_to?(:full_name) ? buyer.full_name : (buyer&.email || 'Client')

        task.update!(
          client_acknowledged_at: Time.current,
          client_acknowledged_by: buyer_name
        )

        render json: {
          success: true,
          task: {
            id: task.id,
            name: task.name,
            acknowledgedAt: task.client_acknowledged_at,
            acknowledgedBy: task.client_acknowledged_by
          }
        }
      end

      private

      # Deal ids belonging to the logged-in buyer (by contact_id or account_id).
      def buyer_deal_ids
        contact = current_portal_buyer&.buyer
        return [] unless contact

        contact_id = contact.id if contact.is_a?(Contact)
        account = contact.is_a?(Account) ? contact : (contact.respond_to?(:account) ? contact.account : nil)

        Deal.where(company_id: current_portal_buyer.company_id)
            .where("contact_id = ? OR account_id = ?", contact_id || 0, account&.id || 0)
            .pluck(:id)
      end

      # Client-visible projects for the logged-in buyer. The single tenant +
      # ownership boundary reused by every action in this controller.
      def buyer_projects
        Project.where(deal_id: buyer_deal_ids, client_visible: true, is_deleted: [false, nil])
      end

      def find_portal_project(id)
        buyer_projects.find_by(id: id)
      end

      # Load + validate the assignment for an approve/revision/reject action,
      # scoped to a project the buyer owns and confirmed still pending. Mirrors
      # the public controller's guard so a buyer can't act on another project's
      # work or re-act on something already decided.
      def load_buyer_review_assignment
        project = find_portal_project(params[:id])
        unless project
          render json: { error: 'Project not found' }, status: :not_found
          return nil
        end

        assignment = ContractorAssignment
                       .where(assignable_type: 'ProjectPhaseTask', client_review_required: true)
                       .find_by(id: params[:assignment_id])

        unless assignment && assignment_in_project?(assignment, project)
          render json: { error: 'Review item not found' }, status: :not_found
          return nil
        end

        unless assignment.client_review_status == ContractorAssignment::CLIENT_REVIEW_PENDING
          render json: { error: 'This item is no longer awaiting your review.' }, status: :unprocessable_entity
          return nil
        end

        assignment
      end

      def assignment_in_project?(assignment, project)
        task = assignment.assignable
        task&.project_phase&.project_id == project.id
      rescue StandardError
        false
      end

      # task_id => ContractorAssignment for client-visible tasks in these phases that
      # are awaiting the customer's approval. One query, keyed for O(1) lookup in
      # serialize_phase. Mirrors the pending_approvals scoping.
      def pending_reviews_by_task(phases)
        task_ids = ProjectPhaseTask.where(project_phase_id: phases.map(&:id), visible_to_client: true).pluck(:id)
        return {} if task_ids.empty?

        ContractorAssignment
          .where(assignable_type: 'ProjectPhaseTask', assignable_id: task_ids)
          .where(client_review_required: true,
                 client_review_status: ContractorAssignment::CLIENT_REVIEW_PENDING)
          .includes(:contractor)
          .index_by(&:assignable_id)
      end

      def serialize_project(project)
        {
          id: project.id,
          name: project.name,
          projectNumber: project.project_number,
          status: project.status,
          progressPercent: project.progress_percent,
          phaseCount: project.phase_count,
          completedPhaseCount: project.completed_phase_count,
          currentPhaseName: project.current_phase_name,
          homeMake: project.home_make,
          homeModel: project.home_model,
          deliveryCity: project.delivery_city,
          deliveryState: project.delivery_state,
          estimatedCompletionDate: project.estimated_completion_date,
          actualCompletionDate: project.actual_completion_date,
          createdAt: project.created_at
        }
      end

      def serialize_phase(phase, project, pending_by_task = {})
        # Load tasks once; reuse for both the task list and the pending-review panel.
        client_tasks = phase.project_phase_tasks
                            .where(visible_to_client: true)
                            .order(:position)
                            .to_a

        {
          id: phase.id,
          name: phase.name,
          description: phase.description,
          position: phase.position,
          status: phase.status,
          statusDisplay: phase.status_display,
          startedAt: phase.started_at,
          completedAt: phase.completed_at,
          estimatedCompletionDate: phase.estimated_completion_date,
          clientNotes: phase.client_notes,
          icon: phase.icon,
          color: phase.color,
          isCurrent: phase.id == project.current_phase_id,
          overdue: phase.overdue?,
          tasks: client_tasks.map { |task| serialize_client_task(task) },
          # Completed contractor work on this phase awaiting THIS buyer's approval.
          # Same shape as the pending_approvals tile rows (extra project context is
          # harmless inline). Drives the inline approve/request-changes/reject panel.
          pendingReviews: client_tasks.filter_map { |task|
            assignment = pending_by_task[task.id]
            assignment ? serialize_pending_approval(assignment, task, phase, project) : nil
          }
        }
      end

      def serialize_pending_approval(assignment, task, phase, project)
        {
          assignmentId: assignment.id,
          projectId: project.id,
          projectName: project.name,
          projectNumber: project.project_number,
          phaseId: phase.id,
          phaseName: phase.name,
          taskId: task.id,
          taskName: task.name,
          contractorName: assignment.contractor&.name || assignment.contractor&.contact_name,
          completionSummary: assignment.completion_summary,
          completionPhotos: assignment.completion_photos || [],
          submittedAt: assignment.submitted_for_review_at
        }
      end

      def serialize_client_task(task)
        {
          id: task.id,
          name: task.name,
          status: task.status,
          isRequired: task.is_required,
          clientActionable: task.client_actionable,
          acknowledgedAt: task.client_acknowledged_at,
          acknowledgedBy: task.client_acknowledged_by,
          completedAt: task.completed_at
        }
      end
    end
  end
end
