module Api
  module V1
    class AgreementTemplatesController < ApplicationController
      before_action :set_company_scope
      before_action :set_template, only: [:show, :update, :destroy, :duplicate, :preview]

      # GET /api/v1/agreement_templates
      def index
        return unless authorize_action!('agreements', 'read')

        templates = @company.agreement_templates.active

        # Filters
        templates = templates.by_status(params[:status]) if params[:status].present?
        templates = templates.by_category(params[:category]) if params[:category].present?
        templates = templates.where(template_type: params[:template_type]) if params[:template_type].present?
        templates = templates.where(agreement_category_id: params[:category_id]) if params[:category_id].present?

        # Stats BEFORE search
        stats = {
          total: templates.count,
          active: templates.where(status: 'active').count,
          draft: templates.where(status: 'draft').count,
          archived: templates.where(status: 'archived').count
        }

        # Search AFTER stats
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          templates = templates.where("name ILIKE ? OR description ILIKE ?", search_term, search_term)
        end

        # Sort
        sort_by = params[:sort_by] || 'updated_at'
        sort_order = params[:sort_order]&.downcase == 'asc' ? 'asc' : 'desc'
        templates = templates.order(sort_by => sort_order)

        # Paginate
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min
        total = templates.count
        templates = templates.offset((page - 1) * per_page).limit(per_page)

        templates = templates.includes(:agreement_category)

        render json: {
          items: templates.map { |t| template_json(t) },
          meta: {
            total: total,
            page: page,
            per_page: per_page,
            total_pages: (total.to_f / per_page).ceil,
            stats: stats
          }
        }
      rescue => e
        Rails.logger.error "Error in agreement_templates#index: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # GET /api/v1/agreement_templates/:id
      def show
        return unless authorize_action!('agreements', 'read')

        render json: template_json(@template, detailed: true)
      end

      # POST /api/v1/agreement_templates
      def create
        return unless authorize_action!('agreements', 'create')

        template = @company.agreement_templates.new(template_params)
        template.created_by = current_user

        if template.save
          render json: template_json(template, detailed: true), status: :created
        else
          render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/agreement_templates/:id
      def update
        return unless authorize_action!('agreements', 'update')

        if @template.update(template_params)
          render json: template_json(@template, detailed: true)
        else
          render json: { errors: @template.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/agreement_templates/:id
      def destroy
        return unless authorize_action!('agreements', 'delete')

        if @template.is_system_template?
          return render json: { error: 'Cannot delete system templates' }, status: :unprocessable_entity
        end

        @template.update!(is_deleted: true)
        head :no_content
      end

      # POST /api/v1/agreement_templates/:id/duplicate
      def duplicate
        return unless authorize_action!('agreements', 'create')

        new_template = @template.duplicate!(current_user)
        render json: template_json(new_template, detailed: true), status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/agreement_templates/:id/preview
      def preview
        return unless authorize_action!('agreements', 'read')

        # Resolve merge fields from entity_ids
        merge_values = resolve_merge_fields(params[:entity_ids] || {})

        render json: {
          template: template_json(@template, detailed: true),
          merge_field_values: merge_values
        }
      end

      private

      def set_company_scope
        unless current_user
          return render json: { error: 'Authentication required' }, status: :unauthorized
        end

        @company = Company.find_by(id: current_company_id)
        unless @company
          return render json: { error: 'Company not found' }, status: :not_found
        end
      end

      def set_template
        @template = @company.agreement_templates.active.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Template not found' }, status: :not_found
      end

      def template_params
        permitted = params.require(:agreement_template).permit(
          :name, :description, :category, :agreement_category_id,
          :document_url, :content, :template_type, :status, :location_id
        )

        # Handle JSON fields
        permitted[:merge_fields] = params[:agreement_template][:merge_fields] if params[:agreement_template][:merge_fields].present?
        permitted[:field_placements] = params[:agreement_template][:field_placements] if params[:agreement_template][:field_placements].present?
        permitted[:default_signers] = params[:agreement_template][:default_signers] if params[:agreement_template][:default_signers].present?

        permitted
      end

      def template_json(template, detailed: false)
        data = {
          id: template.id,
          name: template.name,
          description: template.description,
          category: template.category,
          category_id: template.agreement_category_id,
          category_name: template.agreement_category&.name,
          template_type: template.template_type,
          status: template.status,
          version: template.version,
          is_system_template: template.is_system_template,
          created_at: template.created_at,
          updated_at: template.updated_at
        }

        if detailed
          data.merge!(
            content: template.content,
            document_url: template.document_url,
            merge_fields: template.merge_fields,
            field_placements: template.field_placements,
            default_signers: template.default_signers,
            location_id: template.location_id,
            created_by_id: template.created_by_id
          )
        end

        data
      end

      def resolve_merge_fields(entity_ids)
        values = {}
        # Resolve contact fields
        if entity_ids['contact_id'].present?
          contact = @company.contacts.find_by(id: entity_ids['contact_id'])
          if contact
            values['contact.first_name'] = contact.first_name
            values['contact.last_name'] = contact.last_name
            values['contact.email'] = contact.email
            values['contact.phone'] = contact.phone
            values['contact.full_name'] = contact.full_name
          end
        end
        values
      end
    end
  end
end
