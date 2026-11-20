# frozen_string_literal: true

# GET /api/v1/projects/:project_id/who_hears (E106)
#   change=dates&phase_ids[]=..       every phase the change will move
#   change=status&phase_id=&status=   in_progress | completed
#   change=add_task&phase_id=
#   change=edit_task&phase_id=
module Api
  module V1
    class ProjectChangeAudienceController < ApplicationController
      before_action :set_company_scope

      def show
        return unless authorize_action!('deals', 'read')

        project = @company.projects.where(is_deleted: [false, nil]).find_by(id: params[:project_id])
        return render json: { error: 'Project not found' }, status: :not_found unless project

        audience = ProjectChangeAudience.new(project)
        phase = project.project_phases.find_by(id: params[:phase_id]) if params[:phase_id].present?
        lines = case params[:change]
                when 'dates' then audience.dates(Array(params[:phase_ids]).map(&:to_i))
                when 'status' then phase ? audience.status(phase, params[:status]) : nil
                when 'add_task' then phase ? audience.add_task(phase) : nil
                when 'edit_task' then phase ? audience.edit_task(phase) : nil
                end
        return render json: { error: 'Say what is changing and on which phase' }, status: :unprocessable_entity unless lines

        render json: audience.as_json_for(lines)
      end
    end
  end
end
