# frozen_string_literal: true

module Api
  module V1
    class ProjectTemplatesController < ApplicationController
      before_action :set_company_scope
      before_action :set_template, only: %i[show update destroy duplicate]

      # GET /api/v1/project_templates
      def index
        return unless authorize_action!('project_templates', 'read')

        templates = @company.project_templates.where(is_deleted: [false, nil])

        templates = templates.by_type(params[:template_type]) if params[:template_type].present?
        templates = templates.where(is_active: true) if params[:active_only] == 'true'

        if params[:search].present?
          search_term = "%#{params[:search]}%"
          templates = templates.where("name ILIKE ? OR description ILIKE ?", search_term, search_term)
        end

        templates = templates.order(:name)

        render json: {
          items: templates.as_json(
            only: %i[id name description template_type is_default is_active phase_count location_id created_at updated_at],
            include: {
              project_template_phases: {
                only: %i[id name position visible_to_client is_required estimated_days icon color]
              }
            }
          )
        }
      end

      # GET /api/v1/project_templates/:id
      def show
        return unless authorize_action!('project_templates', 'read')

        render json: {
          template: @template.as_json(
            only: %i[id name description template_type is_default is_active phase_count location_id created_at updated_at],
            include: {
              project_template_phases: {
                only: %i[id name description position visible_to_client is_required
                         notify_client_on_start notify_client_on_complete estimated_days icon color]
              }
            }
          )
        }
      end

      # POST /api/v1/project_templates
      def create
        return unless authorize_action!('project_templates', 'create')

        template = @company.project_templates.build(template_params)
        template.created_by_id = current_user.id

        ActiveRecord::Base.transaction do
          template.save!

          # Create phases if provided
          if params[:phases].is_a?(Array)
            params[:phases].each_with_index do |phase_data, index|
              template.project_template_phases.create!(
                name: phase_data[:name],
                description: phase_data[:description],
                position: phase_data[:position] || index,
                visible_to_client: phase_data[:visible_to_client] != false,
                is_required: phase_data[:is_required] != false,
                notify_client_on_start: phase_data[:notify_client_on_start] || false,
                notify_client_on_complete: phase_data[:notify_client_on_complete] != false,
                estimated_days: phase_data[:estimated_days],
                icon: phase_data[:icon],
                color: phase_data[:color]
              )
            end
          end

          template.reload
          template.update_column(:phase_count, template.project_template_phases.count)
        end

        render json: {
          template: template.as_json(
            only: %i[id name description template_type is_default is_active phase_count created_at],
            include: {
              project_template_phases: {
                only: %i[id name position visible_to_client is_required estimated_days icon color]
              }
            }
          )
        }, status: :created

      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      # PATCH /api/v1/project_templates/:id
      def update
        return unless authorize_action!('project_templates', 'update')

        ActiveRecord::Base.transaction do
          @template.update!(template_params)

          # Replace phases if provided (full replacement — simpler for template editing)
          if params[:phases].is_a?(Array)
            @template.project_template_phases.destroy_all

            params[:phases].each_with_index do |phase_data, index|
              @template.project_template_phases.create!(
                name: phase_data[:name],
                description: phase_data[:description],
                position: phase_data[:position] || index,
                visible_to_client: phase_data[:visible_to_client] != false,
                is_required: phase_data[:is_required] != false,
                notify_client_on_start: phase_data[:notify_client_on_start] || false,
                notify_client_on_complete: phase_data[:notify_client_on_complete] != false,
                estimated_days: phase_data[:estimated_days],
                icon: phase_data[:icon],
                color: phase_data[:color]
              )
            end

            @template.reload
            @template.update_column(:phase_count, @template.project_template_phases.count)
          end
        end

        render json: {
          template: @template.as_json(
            only: %i[id name description template_type is_default is_active phase_count updated_at],
            include: {
              project_template_phases: {
                only: %i[id name position visible_to_client is_required estimated_days icon color]
              }
            }
          )
        }

      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      # DELETE /api/v1/project_templates/:id
      def destroy
        return unless authorize_action!('project_templates', 'delete')

        @template.update!(is_deleted: true, is_active: false)
        render json: { message: 'Template deleted' }
      end

      # POST /api/v1/project_templates/:id/duplicate
      def duplicate
        return unless authorize_action!('project_templates', 'create')

        new_template = @template.duplicate!(new_name: params[:name])
        new_template.update!(created_by_id: current_user.id)

        render json: {
          template: new_template.as_json(
            only: %i[id name description template_type is_default is_active phase_count created_at],
            include: {
              project_template_phases: {
                only: %i[id name position visible_to_client is_required estimated_days icon color]
              }
            }
          )
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
          # NEVER permit: :company_id
        )
      end
    end
  end
end
