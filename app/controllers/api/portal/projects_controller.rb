# frozen_string_literal: true

module Api
  module Portal
    class ProjectsController < ApplicationController
      skip_before_action :authenticate
      before_action :authenticate_portal_buyer!

      # GET /api/portal/projects
      def index
        contact = current_portal_buyer&.buyer
        return render(json: { success: true, data: [] }) unless contact

        # Find deals for this contact (by contact_id or account_id)
        contact_id = contact.id if contact.is_a?(Contact)
        account = contact.is_a?(Account) ? contact : (contact.respond_to?(:account) ? contact.account : nil)

        deal_ids = Deal.where(company_id: current_portal_buyer.company_id)
                       .where("contact_id = ? OR account_id = ?",
                              contact_id || 0,
                              account&.id || 0)
                       .pluck(:id)

        projects = Project.where(deal_id: deal_ids, client_visible: true, is_deleted: [false, nil])
                          .order(created_at: :desc)

        render json: {
          success: true,
          data: projects.map { |project| serialize_project(project) }
        }
      end

      # GET /api/portal/projects/:id
      def show
        project = find_portal_project(params[:id])
        return render(json: { error: 'Project not found' }, status: :not_found) unless project

        phases = project.project_phases.where(visible_to_client: true).order(:position)

        render json: {
          success: true,
          data: serialize_project(project),
          phases: phases.map { |phase| serialize_phase(phase, project) }
        }
      end

      private

      def find_portal_project(id)
        contact = current_portal_buyer&.buyer
        return nil unless contact

        contact_id = contact.id if contact.is_a?(Contact)
        account = contact.is_a?(Account) ? contact : (contact.respond_to?(:account) ? contact.account : nil)

        deal_ids = Deal.where(company_id: current_portal_buyer.company_id)
                       .where("contact_id = ? OR account_id = ?",
                              contact_id || 0,
                              account&.id || 0)
                       .pluck(:id)

        Project.where(id: id, deal_id: deal_ids, client_visible: true, is_deleted: [false, nil]).first
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

      def serialize_phase(phase, project)
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
          overdue: phase.overdue?
        }
      end
    end
  end
end
