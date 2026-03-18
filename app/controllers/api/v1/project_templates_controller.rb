# frozen_string_literal: true

module Api
  module V1
    class ProjectTemplatesController < ApplicationController
      before_action :set_company_scope
      before_action :set_template, only: %i[show update destroy duplicate]

      PHASE_ONLY_FIELDS = %i[id name position visible_to_client is_required estimated_days icon color].freeze
      PHASE_TASK_FIELDS = %i[id name position is_required].freeze

      def phases_json(phases)
        phases.includes(:project_template_phase_tasks).map do |phase|
          phase.as_json(
            only: %i[id name description position visible_to_client is_required
                     notify_client_on_start notify_client_on_complete estimated_days icon color],
            include: {
              project_template_phase_tasks: { only: PHASE_TASK_FIELDS }
            }
          ).merge('default_tasks' => phase.default_tasks || [])
        end
      end

      # GET /api/v1/project_templates
      def index
        return unless authorize_action!('deals', 'read')

        templates = @company.project_templates.where(is_deleted: [false, nil])
        templates = templates.by_type(params[:template_type]) if params[:template_type].present?
        templates = templates.where(is_active: true) if params[:active_only] == 'true'

        if params[:search].present?
          search_term = "%#{params[:search]}%"
          templates = templates.where("name ILIKE ? OR description ILIKE ?", search_term, search_term)
        end

        templates = templates.order(:name)

        render json: {
          items: templates.map do |t|
            t.as_json(only: %i[id name description template_type is_default is_active phase_count location_id created_at updated_at])
              .merge('project_template_phases' => phases_json(t.project_template_phases.ordered))
          end
        }
      end

      # GET /api/v1/project_templates/:id
      def show
        return unless authorize_action!('deals', 'read')

        render json: {
          template: @template.as_json(
            only: %i[id name description template_type is_default is_active phase_count location_id created_at updated_at]
          ).merge('project_template_phases' => phases_json(@template.project_template_phases.ordered))
        }
      end

      # POST /api/v1/project_templates
      def create
        return unless authorize_action!('deals', 'create')

        template = @company.project_templates.build(template_params)
        template.created_by_id = current_user.id

        ActiveRecord::Base.transaction do
          template.save!
          build_phases!(template, params[:phases]) if params[:phases].is_a?(Array)
          template.reload
          template.update_column(:phase_count, template.project_template_phases.count)
        end

        render json: {
          template: template.as_json(only: %i[id name description template_type is_default is_active phase_count created_at])
            .merge('project_template_phases' => phases_json(template.project_template_phases.ordered))
        }, status: :created

      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      # PATCH /api/v1/project_templates/:id
      def update
        return unless authorize_action!('deals', 'update')

        ActiveRecord::Base.transaction do
          @template.update!(template_params)

          if params[:phases].is_a?(Array)
            @template.project_template_phases.destroy_all
            build_phases!(@template, params[:phases])
            @template.reload
            @template.update_column(:phase_count, @template.project_template_phases.count)
          end
        end

        render json: {
          template: @template.as_json(only: %i[id name description template_type is_default is_active phase_count updated_at])
            .merge('project_template_phases' => phases_json(@template.project_template_phases.ordered))
        }

      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      # DELETE /api/v1/project_templates/:id
      def destroy
        return unless authorize_action!('deals', 'delete')

        @template.update!(is_deleted: true, is_active: false)
        render json: { message: 'Template deleted' }
      end

      # POST /api/v1/project_templates/:id/duplicate
      def duplicate
        return unless authorize_action!('deals', 'create')

        new_template = @template.duplicate!(new_name: params[:name])
        new_template.update!(created_by_id: current_user.id)

        render json: {
          template: new_template.as_json(only: %i[id name description template_type is_default is_active phase_count created_at])
            .merge('project_template_phases' => phases_json(new_template.project_template_phases.ordered))
        }, status: :created
      end

      private

      def set_template
        @template = @company.project_templates.where(is_deleted: [false, nil]).find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Template not found' }, status: :not_found
      end

      def template_params
        params.require(:project_template).permit(
          :name, :description, :template_type, :is_default, :is_active, :location_id
        )
      end

      # Build phases (and their tasks) from params array
      # Saves to BOTH systems:
      #   - project_template_phase_tasks table (Phase 1 backward compat)
      #   - default_tasks JSONB column (Phase 2A rich tasks used by create_project!)
      def build_phases!(template, phases_data)
        phases_data.each_with_index do |phase_data, index|
          # Build default_tasks JSON from the rich task data
          rich_tasks = []
          if phase_data[:tasks].is_a?(Array)
            phase_data[:tasks].each_with_index do |task_data, tidx|
              next if task_data[:name].blank?
              rich_tasks << {
                'name' => task_data[:name],
                'task_type' => task_data[:task_type] || 'task',
                'position' => task_data[:position] || tidx,
                'estimated_hours' => task_data[:estimated_hours],
                'checklist_items' => task_data[:checklist_items] || []
              }
            end
          end

          phase = template.project_template_phases.create!(
            name:                      phase_data[:name],
            description:               phase_data[:description],
            position:                  phase_data[:position] || index,
            visible_to_client:         phase_data[:visible_to_client] != false,
            is_required:               phase_data[:is_required] != false,
            notify_client_on_start:    phase_data[:notify_client_on_start] || false,
            notify_client_on_complete: phase_data[:notify_client_on_complete] != false,
            estimated_days:            phase_data[:estimated_days],
            icon:                      phase_data[:icon],
            color:                     phase_data[:color],
            default_tasks:             rich_tasks
          )

          # Also create Phase 1 simple tasks for backward compat
          next unless phase_data[:tasks].is_a?(Array)
          phase_data[:tasks].each_with_index do |task_data, tidx|
            next if task_data[:name].blank?
            phase.project_template_phase_tasks.create!(
              name:        task_data[:name],
              position:    task_data[:position] || tidx,
              is_required: task_data[:is_required] || false
            )
          end
        end
      end
    end
  end
end
