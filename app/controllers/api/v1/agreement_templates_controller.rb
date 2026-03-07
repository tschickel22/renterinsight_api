module Api
  module V1
    class AgreementTemplatesController < ApplicationController
      before_action :set_company_scope
      before_action :set_template, only: [
        :show, :update, :destroy, :duplicate, :preview,
        :list_custom_fields, :add_custom_field, :update_custom_field, :remove_custom_field,
        :reorder_custom_fields, :validate_formula
      ]

      # GET /api/v1/agreement_templates
      def index
        return unless authorize_action!('agreements', 'read')

        templates = AgreementTemplate.available_for_company(@company, state_code: params[:state_code])

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

      # GET /api/v1/agreement_templates/:id/custom_fields
      def list_custom_fields
        return unless authorize_action!('agreements', 'read')

        definitions = @template.custom_field_definitions || []
        engine = FormulaEngine.new
        all_keys = definitions.map { |d| d['key'] || d[:key] }

        grouped = definitions.group_by { |d| d['group'] || d[:group] || 'general' }

        # Add formula validation status to each formula field
        grouped.transform_values! do |fields|
          fields.map do |field|
            f = field.stringify_keys
            if f['formula'].present? && f['formula'].start_with?('=')
              validation = engine.validate_formula(f['formula'], all_keys)
              f.merge('formula_valid' => validation[:valid], 'formula_error' => validation[:error])
            else
              f
            end
          end
        end

        render json: { custom_field_definitions: grouped }
      end

      # POST /api/v1/agreement_templates/:id/custom_fields
      def add_custom_field
        return unless authorize_action!('agreements', 'update')
        return if platform_template_guard!

        field_params = custom_field_params
        definitions = (@template.custom_field_definitions || []).map(&:stringify_keys)

        # Auto-generate key from label if not provided
        key = field_params['key'].presence || "cf_#{field_params['label'].to_s.parameterize(separator: '_')}"
        field_params['key'] = key

        # Validate key uniqueness
        if definitions.any? { |d| d['key'] == key }
          return render json: { error: "Field key '#{key}' already exists" }, status: :unprocessable_entity
        end

        # Validate type
        unless FormulaEngine::VALID_FIELD_TYPES.include?(field_params['type'])
          return render json: { error: "Invalid field type '#{field_params['type']}'. Valid types: #{FormulaEngine::VALID_FIELD_TYPES.join(', ')}" }, status: :unprocessable_entity
        end

        # Validate formula if present
        if field_params['formula'].present?
          all_keys = definitions.map { |d| d['key'] } + [key]
          validation = FormulaEngine.new.validate_formula(field_params['formula'], all_keys)
          unless validation[:valid]
            return render json: { error: "Invalid formula: #{validation[:error]}" }, status: :unprocessable_entity
          end
        end

        definitions << field_params
        @template.update!(custom_field_definitions: definitions)

        render json: { custom_field_definitions: @template.custom_field_definitions }, status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/agreement_templates/:id/custom_fields/:field_key
      def update_custom_field
        return unless authorize_action!('agreements', 'update')
        return if platform_template_guard!

        definitions = (@template.custom_field_definitions || []).map(&:stringify_keys)
        field_index = definitions.index { |d| d['key'] == params[:field_key] }

        unless field_index
          return render json: { error: "Field '#{params[:field_key]}' not found" }, status: :not_found
        end

        updates = custom_field_params.except('key') # key is immutable

        # Validate formula if being updated
        if updates['formula'].present?
          all_keys = definitions.map { |d| d['key'] }
          validation = FormulaEngine.new.validate_formula(updates['formula'], all_keys)
          unless validation[:valid]
            return render json: { error: "Invalid formula: #{validation[:error]}" }, status: :unprocessable_entity
          end
        end

        # Validate type if being updated
        if updates['type'].present? && !FormulaEngine::VALID_FIELD_TYPES.include?(updates['type'])
          return render json: { error: "Invalid field type '#{updates['type']}'" }, status: :unprocessable_entity
        end

        definitions[field_index] = definitions[field_index].merge(updates)
        @template.update!(custom_field_definitions: definitions)

        render json: { custom_field_definitions: @template.custom_field_definitions }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/agreement_templates/:id/custom_fields/:field_key
      def remove_custom_field
        return unless authorize_action!('agreements', 'update')
        return if platform_template_guard!

        definitions = (@template.custom_field_definitions || []).map(&:stringify_keys)
        original_count = definitions.length
        definitions.reject! { |d| d['key'] == params[:field_key] }

        if definitions.length == original_count
          return render json: { error: "Field '#{params[:field_key]}' not found" }, status: :not_found
        end

        @template.update!(custom_field_definitions: definitions)
        render json: { custom_field_definitions: @template.custom_field_definitions }
      end

      # POST /api/v1/agreement_templates/:id/custom_fields/reorder
      def reorder_custom_fields
        return unless authorize_action!('agreements', 'update')
        return if platform_template_guard!

        reorder_data = params[:fields]
        unless reorder_data.is_a?(Array)
          return render json: { error: 'Expected fields array' }, status: :unprocessable_entity
        end

        definitions = (@template.custom_field_definitions || []).map(&:stringify_keys)

        reorder_data.each do |item|
          item = item.respond_to?(:to_unsafe_h) ? item.to_unsafe_h.stringify_keys : item.stringify_keys
          field = definitions.find { |d| d['key'] == item['key'] }
          next unless field
          field['position'] = item['position'].to_i if item['position'].present?
          field['group'] = item['group'] if item['group'].present?
        end

        @template.update!(custom_field_definitions: definitions)
        render json: { custom_field_definitions: @template.custom_field_definitions }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/agreement_templates/:id/custom_fields/validate_formula
      def validate_formula
        return unless authorize_action!('agreements', 'read')

        formula = params[:formula].to_s
        definitions = @template.custom_field_definitions || []
        all_keys = definitions.map { |d| d['key'] || d[:key] }

        result = FormulaEngine.new.validate_formula(formula, all_keys)
        render json: result
      end

      private

      def set_template
        @template = AgreementTemplate.available_for_company(@company).find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Template not found' }, status: :not_found
      end

      def template_params
        permitted = params.require(:agreement_template).permit(
          :name, :description, :category, :agreement_category_id,
          :document_url, :content, :template_type, :status, :location_id,
          :state_code, :form_type, :form_number, :page_count,
          default_signers: [:role, :label, :order_index],
          custom_field_definitions: []
        )

        # Handle JSON array fields that can't be expressed in permit() syntax
        if params[:agreement_template][:merge_fields].present?
          permitted[:merge_fields] = params[:agreement_template][:merge_fields]
        end

        if params[:agreement_template][:field_placements].present?
          raw = params[:agreement_template][:field_placements]
          permitted[:field_placements] = raw.is_a?(Array) ? raw.map { |fp| fp.respond_to?(:to_unsafe_h) ? fp.to_unsafe_h : fp } : raw
        end

        if params[:agreement_template][:merge_field_placements].present?
          raw = params[:agreement_template][:merge_field_placements]
          permitted[:merge_field_placements] = raw.is_a?(Array) ? raw.map { |fp| fp.respond_to?(:to_unsafe_h) ? fp.to_unsafe_h : fp } : raw
        end

        if params[:agreement_template][:document_urls].present?
          permitted[:document_urls] = params[:agreement_template][:document_urls]
        end

        if params[:agreement_template][:custom_field_definitions].present?
          raw = params[:agreement_template][:custom_field_definitions]
          permitted[:custom_field_definitions] = raw.is_a?(Array) ? raw.map { |fd| fd.respond_to?(:to_unsafe_h) ? fd.to_unsafe_h : fd } : raw
        end

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
          state_code: template.state_code,
          form_type: template.form_type,
          form_number: template.form_number,
          is_platform_template: template.is_platform_template,
          page_count: template.page_count,
          created_at: template.created_at,
          updated_at: template.updated_at
        }

        if detailed
          data.merge!(
            content: template.content,
            document_url: template.document_url,
            document_urls: template.document_urls,
            merge_fields: template.merge_fields,
            field_placements: template.field_placements,
            merge_field_placements: template.merge_field_placements,
            default_signers: template.default_signers,
            location_id: template.location_id,
            created_by_id: template.created_by_id,
            custom_field_definitions: template.custom_field_definitions
          )
        end

        data
      end

      def custom_field_params
        raw = params[:custom_field] || params[:custom_field_definition] || {}
        raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
        raw.stringify_keys.slice(
          'key', 'label', 'type', 'group', 'page', 'required', 'position',
          'formula', 'options', 'format_as', 'placeholder', 'filled_by', 'merge_from'
        )
      end

      def platform_template_guard!
        return false unless @template.is_platform_template?

        unless current_user&.role.in?(%w[platform_admin tenant super_admin])
          render json: { error: 'Only platform admins can modify platform template fields' }, status: :forbidden
          return true
        end

        false
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
