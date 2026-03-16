# frozen_string_literal: true

class Api::V1::Public::ProjectProgressController < ApplicationController
  skip_before_action :authenticate

  # GET /api/v1/public/project-progress/:token
  def show
    project = Project.find_by(client_access_token: params[:token], is_deleted: [false, nil])
    return render(json: { error: 'Project not found' }, status: :not_found) unless project
    return render(json: { error: 'Project is not visible to clients' }, status: :forbidden) unless project.client_visible?

    company = project.company

    # Resolve branding
    brand_settings = {}
    if project.location.present?
      brand_settings = Setting.get('Location', project.location_id, 'branding') rescue {}
    end
    brand_settings = Setting.get('Company', company.id, 'branding') rescue {} if brand_settings.blank?
    brand_settings ||= {}

    # Only return client-visible phases
    phases = project.project_phases.client_visible.ordered

    render json: {
      project: {
        name: project.name,
        project_number: project.project_number,
        status: project.status,
        progress_percent: project.progress_percent,
        customer_name: project.customer_name,
        home_make: project.home_make,
        home_model: project.home_model,
        delivery_city: project.delivery_city,
        delivery_state: project.delivery_state,
        estimated_completion_date: project.estimated_completion_date,
        actual_completion_date: project.actual_completion_date,
        current_phase_name: project.current_phase_name
      },
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
          is_current: phase.id == project.current_phase_id,
          overdue: phase.overdue?
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
end
