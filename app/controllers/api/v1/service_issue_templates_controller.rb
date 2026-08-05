# frozen_string_literal: true

module Api
  module V1
    # CRUD for the canned-complaint library that backs the "From Template"
    # picker on a service ticket's issues.
    class ServiceIssueTemplatesController < ApplicationController
      before_action :set_company
      before_action :set_template, only: %i[update destroy]

      # GET /api/v1/service-issue-templates
      def index
        return unless authorize_action!('service', 'read')

        templates = @company.service_issue_templates.active.ordered
        templates = templates.for_category(params[:category]) if params[:category].present?
        templates = templates.for_location(current_location_id)

        render json: {
          templates: templates.map { |t| serialize_template(t) },
          categories: ServiceIssueTemplate::CATEGORIES
        }
      end

      # POST /api/v1/service-issue-templates
      #
      # Upsert by title, matching how package_templates behaves: saving the
      # same complaint twice from a ticket updates the library entry instead of
      # erroring or duplicating it.
      def create
        return unless authorize_action!('service', 'create')

        existing = @company.service_issue_templates
                           .active
                           .where('lower(title) = ?', template_params[:title].to_s.downcase)
                           .first

        if existing
          existing.update(template_params)
          return render json: { template: serialize_template(existing), existing: true }
        end

        template = @company.service_issue_templates.new(template_params)
        template.location_id ||= current_location_id

        if template.save
          render json: { template: serialize_template(template) }, status: :created
        else
          render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/service-issue-templates/:id
      def update
        return unless authorize_action!('service', 'update')

        if @template.update(template_params)
          render json: { template: serialize_template(@template) }
        else
          render json: { errors: @template.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/service-issue-templates/:id -- soft delete, so tickets
      # already built from a retired template keep their provenance.
      def destroy
        return unless authorize_action!('service', 'delete')

        @template.update!(is_active: false)
        render json: { success: true }
      end

      # POST /api/v1/service-issue-templates/reorder
      def reorder
        return unless authorize_action!('service', 'update')

        ids = params[:ordered_ids] || params[:ids] || []
        ids.each_with_index do |id, index|
          @company.service_issue_templates.where(id: id).update_all(position: index)
        end

        render json: { success: true }
      end

      private

      def set_company
        return render json: { error: 'Authentication required' }, status: :unauthorized unless current_user

        @company = current_company
        render json: { error: 'Company not found' }, status: :not_found if @company.nil?
      end

      def set_template
        @template = @company.service_issue_templates.find_by(id: params[:id])
        render json: { error: 'Template not found' }, status: :not_found if @template.nil?
      end

      def current_location_id
        Current.respond_to?(:location_id) ? Current.location_id : nil
      end

      def template_params
        params.require(:template).permit(
          :title, :category, :complaint, :correction,
          :default_pay_type, :default_hours, :default_rate,
          :position, :is_active, :location_id,
          default_parts: %i[partNumber description partId quantity unitCost]
        )
      end

      def serialize_template(template)
        {
          id: template.id,
          title: template.title,
          category: template.category,
          complaint: template.complaint,
          correction: template.correction,
          defaultPayType: template.default_pay_type,
          defaultHours: template.default_hours,
          defaultRate: template.default_rate,
          defaultParts: template.default_parts,
          position: template.position,
          isActive: template.is_active,
          locationId: template.location_id,
          createdAt: template.created_at,
          updatedAt: template.updated_at
        }
      end
    end
  end
end
