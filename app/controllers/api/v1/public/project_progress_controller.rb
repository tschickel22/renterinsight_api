# frozen_string_literal: true

class Api::V1::Public::ProjectProgressController < ApplicationController
  skip_before_action :authenticate

  before_action :load_project, only: %i[show approve request_revision reject]

  # GET /api/v1/public/project-progress/:token
  def show
    company = @project.company

    # Resolve branding
    brand_settings = {}
    if @project.location.present?
      brand_settings = Setting.get('Location', @project.location_id, 'branding') rescue {}
    end
    brand_settings = Setting.get('Company', company.id, 'branding') rescue {} if brand_settings.blank?
    brand_settings ||= {}

    # Only return client-visible phases
    phases = @project.project_phases.client_visible.ordered

    # Preload the contractor assignments that are awaiting CUSTOMER review across
    # all client-visible phase tasks, so the public page can render an "approve /
    # request changes / reject" panel inline on the relevant task.
    pending_client_reviews = client_pending_reviews_by_task(phases)

    render json: {
      project: {
        name: @project.name,
        project_number: @project.project_number,
        status: @project.status,
        progress_percent: @project.progress_percent,
        customer_name: @project.customer_name,
        home_make: @project.home_make,
        home_model: @project.home_model,
        delivery_city: @project.delivery_city,
        delivery_state: @project.delivery_state,
        estimated_completion_date: @project.estimated_completion_date,
        actual_completion_date: @project.actual_completion_date,
        current_phase_name: @project.current_phase_name
      },
      # Surfaced so the frontend can decide whether to show the approval UI at all.
      client_approval_enabled: client_approval_enabled?(company),
      phases: phases.map do |phase|
        {
          id: phase.id,
          name: phase.name,
          description: phase.description,
          position: phase.position,
          status: phase.status,
          status_display: phase.status_display,
          started_at: phase.started_at,
          completed_at: phase.completed_at,
          estimated_completion_date: phase.estimated_completion_date,
          client_notes: phase.client_notes,
          icon: phase.icon,
          color: phase.color,
          is_current: phase.id == @project.current_phase_id,
          overdue: phase.overdue?,
          # Tasks awaiting this customer's approval, if any.
          pending_reviews: phase.project_phase_tasks.client_visible.ordered.filter_map do |task|
            review = pending_client_reviews[task.id]
            next unless review
            client_review_json(task, review)
          end
        }
      end,
      branding: {
        company_name: company.name,
        logo: brand_settings['logo'] || brand_settings[:logo],
        primary_color: brand_settings['primary_color'] || brand_settings[:primary_color] || '#3b82f6',
        phone: company.phone,
        email: company.email
      }
    }
  end

  # POST /api/v1/public/project-progress/:token/reviews/:assignment_id/approve
  def approve
    assignment = load_client_review_assignment
    return unless assignment

    assignment.client_approve!(notes: params[:notes])
    render json: { success: true, message: 'Thank you — your approval has been recorded.' }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/public/project-progress/:token/reviews/:assignment_id/request_revision
  def request_revision
    assignment = load_client_review_assignment
    return unless assignment

    if params[:notes].blank?
      return render json: { error: 'Please tell us what needs to change.' }, status: :unprocessable_entity
    end

    assignment.client_request_revision!(notes: params[:notes])
    render json: { success: true, message: 'Thanks — we have asked the contractor to make the changes.' }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/public/project-progress/:token/reviews/:assignment_id/reject
  def reject
    assignment = load_client_review_assignment
    return unless assignment

    assignment.client_reject!(notes: params[:notes])
    render json: { success: true, message: 'Thanks — we have let the team know.' }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def load_project
    @project = Project.find_by(client_access_token: params[:token], is_deleted: [false, nil])
    return render(json: { error: 'Project not found' }, status: :not_found) unless @project
    return render(json: { error: 'Project is not visible to clients' }, status: :forbidden) unless @project.client_visible?
  end

  # Find the assignment for an action, scoped to THIS project and confirmed to
  # still be awaiting the customer's review. Token + project scoping prevents a
  # customer acting on another project's tasks.
  def load_client_review_assignment
    assignment = ContractorAssignment
      .where(assignable_type: 'ProjectPhaseTask', client_review_required: true)
      .find_by(id: params[:assignment_id])

    unless assignment && assignment_belongs_to_project?(assignment)
      render json: { error: 'Review item not found' }, status: :not_found
      return nil
    end

    unless assignment.client_review_status == ContractorAssignment::CLIENT_REVIEW_PENDING
      render json: { error: 'This item is no longer awaiting your review.' }, status: :unprocessable_entity
      return nil
    end

    assignment
  end

  def assignment_belongs_to_project?(assignment)
    task = assignment.assignable
    task&.project_phase&.project_id == @project.id
  rescue
    false
  end

  # Map of task_id => ContractorAssignment for all tasks in the given phases that
  # are currently awaiting customer review. One query, keyed for O(1) lookup.
  def client_pending_reviews_by_task(phases)
    task_ids = ProjectPhaseTask.where(project_phase_id: phases.map(&:id)).pluck(:id)
    return {} if task_ids.empty?

    ContractorAssignment
      .where(assignable_type: 'ProjectPhaseTask', assignable_id: task_ids)
      .where(client_review_required: true, client_review_status: ContractorAssignment::CLIENT_REVIEW_PENDING)
      .includes(:contractor)
      .index_by(&:assignable_id)
  end

  def client_review_json(task, assignment)
    {
      assignment_id: assignment.id,
      task_id: task.id,
      task_name: task.name,
      contractor_name: assignment.contractor&.name || assignment.contractor&.contact_name,
      completion_summary: assignment.completion_summary,
      completion_photos: assignment.completion_photos || [],
      submitted_at: assignment.submitted_for_review_at
    }
  end

  def client_approval_enabled?(company)
    cfg = Setting.get('company', company.id, 'project_management')
    return false if cfg.blank?

    flag = cfg.is_a?(Hash) ? (cfg['require_client_approval'] || cfg[:require_client_approval]) : false
    ActiveModel::Type::Boolean.new.cast(flag) || false
  rescue
    false
  end
end
