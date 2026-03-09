module Api
  module V1
    class AgreementTemplatesController < ApplicationController
      before_action :set_company_scope
      before_action :set_template, only: [
        :show, :update, :destroy, :duplicate, :preview, :vision_scan,
        :list_custom_fields, :add_custom_field, :update_custom_field, :remove_custom_field,
        :reorder_custom_fields, :validate_formula
      ]

      # GET /api/v1/agreement_templates
      def index
        return unless authorize_action!('agreements', 'read')

        # admin_view=true is only sent by Platform Forms management tab
        # Regular template picker always uses state-filtered available_for_company
        if params[:admin_view] == 'true' && current_user&.role.in?(%w[platform_admin tenant super_admin])
          company_templates = AgreementTemplate.where(company_id: @company.id, is_deleted: false)
                                .where(is_platform_template: [false, nil])
          platform_templates = AgreementTemplate.where(is_platform_template: true, is_deleted: false)
                                .where(is_master: [false, nil])  # Masters not shown in picker
          platform_templates = platform_templates.where(state_code: params[:state_code]) if params[:state_code].present?
          templates = AgreementTemplate.where(id: company_templates.select(:id))
                       .or(AgreementTemplate.where(id: platform_templates.select(:id)))
        else
          templates = AgreementTemplate.available_for_company(@company, state_code: params[:state_code])
        end

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

      # POST /api/v1/agreement_templates/:id/vision_scan
      def vision_scan
        return unless authorize_action!('agreements', 'update')

        unless @template.document_url.present?
          return render json: { error: 'No PDF document uploaded for this template' }, status: :unprocessable_entity
        end

        api_key = ENV['ANTHROPIC_API_KEY'] || Rails.application.credentials.dig(:anthropic, :api_key)
        unless api_key.present?
          return render json: { error: 'AI scanning is not configured. Please add an Anthropic API key.' }, status: :service_unavailable
        end

        begin
          service = AgreementVisionScanService.new(api_key)
          result = service.scan(@template.document_url, max_pages: params[:max_pages]&.to_i || 16)

          render json: {
            fields: result[:fields],
            pages_scanned: result[:pages_scanned],
            total_pages: result[:total_pages],
          }
        rescue AgreementVisionScanService::ScanError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue => e
          Rails.logger.error "[VisionScan Template] #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
          render json: { error: 'Vision scan failed. Please try again.' }, status: :internal_server_error
        end
      end

      # GET /api/v1/agreement_templates/state_groups
      def state_groups
        return unless authorize_action!('agreements', 'read')
        unless current_user&.role.in?(%w[platform_admin tenant super_admin])
          return render json: { error: 'Platform admin access required' }, status: :forbidden
        end

        platform_templates = AgreementTemplate
          .where(is_platform_template: true, is_deleted: false)
          .order(:template_group_id, :state_code)

        groups = {}
        ungrouped = []

        platform_templates.each do |t|
          if t.template_group_id.present?
            groups[t.template_group_id] ||= {
              group_id: t.template_group_id,
              form_number: t.form_number,
              form_type: t.form_type,
              name: nil,
              master_id: nil,
              states: [],
              total_states: 0,
              created_at: t.created_at,
              updated_at: t.updated_at
            }

            if t.is_master?
              # Master template — use its name as the group name, store its ID
              groups[t.template_group_id][:master_id] = t.id
              groups[t.template_group_id][:name] = t.name
            else
              # State copy — add to states list
              groups[t.template_group_id][:states] << {
                id: t.id,
                state_code: t.state_code,
                status: t.status,
                page_count: t.page_count,
                custom_fields_count: (t.custom_field_definitions || []).length,
                field_placements_count: (t.field_placements || []).length + (t.merge_field_placements || []).length,
                updated_at: t.updated_at
              }
              groups[t.template_group_id][:total_states] += 1
            end

            # Fallback name from state copies if no master yet (legacy groups)
            if groups[t.template_group_id][:name].nil? && !t.is_master?
              groups[t.template_group_id][:name] = t.name.gsub(/ - [A-Z]{2}$/, '')
            end

            if t.updated_at > groups[t.template_group_id][:updated_at]
              groups[t.template_group_id][:updated_at] = t.updated_at
            end
          else
            ungrouped << {
              id: t.id,
              name: t.name,
              state_code: t.state_code,
              form_number: t.form_number,
              form_type: t.form_type,
              status: t.status,
              updated_at: t.updated_at
            }
          end
        end

        render json: {
          groups: groups.values.sort_by { |g| g[:name] },
          ungrouped: ungrouped
        }
      end

      # POST /api/v1/agreement_templates/multi_state_create
      def multi_state_create
        return unless authorize_action!('agreements', 'create')
        unless current_user&.role.in?(%w[platform_admin tenant super_admin])
          return render json: { error: 'Platform admin access required' }, status: :forbidden
        end

        state_codes = params[:state_codes]
        unless state_codes.is_a?(Array) && state_codes.length > 0
          return render json: { error: 'At least one state_code is required' }, status: :unprocessable_entity
        end

        invalid = state_codes.reject { |sc| US_STATE_CODES.key?(sc.upcase) }
        if invalid.any?
          return render json: { error: "Invalid state codes: #{invalid.join(', ')}" }, status: :unprocessable_entity
        end

        existing_group_id = params[:template_group_id].presence
        group_id = existing_group_id || "form_#{SecureRandom.hex(6)}_#{Time.current.strftime('%Y%m%d')}"
        base_params = multi_state_template_params
        base_name = base_params[:name] || 'Form 500'

        created = []
        errors_list = []
        master_id = nil

        ActiveRecord::Base.transaction do
          # Create master record for new groups (not when adding states to existing group)
          if existing_group_id.blank?
            master = AgreementTemplate.new(base_params.except(:name))
            master.company_id = @company.id
            master.name = base_name
            master.state_code = nil
            master.is_platform_template = true
            master.is_master = true
            master.template_group_id = group_id
            master.status = 'draft'
            master.created_by = current_user
            master.save!
            master_id = master.id
          else
            # Find existing master to copy fields from
            existing_master = AgreementTemplate.find_by(
              template_group_id: existing_group_id, is_master: true, is_deleted: false
            )
            master_id = existing_master&.id
          end

          # Create state copies
          state_codes.each do |sc|
            sc = sc.upcase
            state_name = US_STATE_CODES[sc] || sc

            existing = AgreementTemplate.where(
              is_platform_template: true,
              state_code: sc,
              form_number: base_params[:form_number],
              is_deleted: false
            ).where(is_master: [false, nil]).first

            if existing
              errors_list << { state_code: sc, error: "Template already exists for #{state_name} (ID: #{existing.id})" }
              next
            end

            template = AgreementTemplate.new(base_params.except(:name))
            template.company_id = @company.id
            template.name = "#{base_name} - #{sc}"
            template.state_code = sc
            template.is_platform_template = true
            template.is_master = false
            template.template_group_id = group_id
            template.status = 'draft'
            template.created_by = current_user

            if template.save
              created << { id: template.id, state_code: sc, state_name: state_name, name: template.name }
            else
              errors_list << { state_code: sc, error: template.errors.full_messages.join(', ') }
            end
          end

          raise ActiveRecord::Rollback if created.empty? && errors_list.any?
        end

        render json: {
          group_id: group_id,
          master_id: master_id,
          created: created,
          errors: errors_list,
          message: "Created #{created.length} template(s)#{errors_list.any? ? ", #{errors_list.length} skipped" : ''}"
        }, status: created.any? ? :created : :unprocessable_entity
      end

      # PATCH /api/v1/agreement_templates/multi_state_update
      def multi_state_update
        return unless authorize_action!('agreements', 'update')
        unless current_user&.role.in?(%w[platform_admin tenant super_admin])
          return render json: { error: 'Platform admin access required' }, status: :forbidden
        end

        templates = if params[:template_ids].present?
          AgreementTemplate.where(id: params[:template_ids], is_platform_template: true, is_deleted: false)
        elsif params[:group_id].present?
          AgreementTemplate.where(template_group_id: params[:group_id], is_deleted: false)
        else
          return render json: { error: 'template_ids or group_id required' }, status: :unprocessable_entity
        end

        if templates.empty?
          return render json: { error: 'No templates found' }, status: :not_found
        end

        allowed_update_fields = %w[
          document_url document_urls field_placements merge_field_placements
          custom_field_definitions default_signers page_count status
          name description form_number form_type
        ]
        update_fields = (params[:update_fields] || allowed_update_fields).map(&:to_s) & allowed_update_fields

        raw = params[:template] || params[:agreement_template] || {}
        raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
        update_data = raw.slice(*update_fields).compact

        rename_base = update_data.delete('name')

        updated = []
        errors_list = []

        templates.each do |template|
          begin
            attrs = update_data.dup
            if rename_base.present?
              if template.is_master?
                # Master gets the base name (no state suffix)
                attrs['name'] = rename_base
              elsif template.state_code.present?
                attrs['name'] = "#{rename_base} - #{template.state_code}"
              end
            end
            template.update!(attrs.symbolize_keys)
            updated << { id: template.id, state_code: template.state_code, name: template.name, is_master: template.is_master? }
          rescue => e
            errors_list << { id: template.id, state_code: template.state_code, error: e.message }
          end
        end

        render json: {
          updated: updated,
          errors: errors_list,
          message: "Updated #{updated.length} template(s)#{errors_list.any? ? ", #{errors_list.length} failed" : ''}"
        }
      end

      # DELETE /api/v1/agreement_templates/delete_group
      # Soft-deletes all templates in a group, or specific template_ids
      def delete_group
        return unless authorize_action!('agreements', 'delete')
        unless current_user&.role.in?(%w[platform_admin tenant super_admin])
          return render json: { error: 'Platform admin access required' }, status: :forbidden
        end

        templates = if params[:template_ids].present?
          AgreementTemplate.where(id: params[:template_ids], is_deleted: false)
        elsif params[:group_id].present?
          AgreementTemplate.where(template_group_id: params[:group_id], is_deleted: false)
        else
          return render json: { error: 'template_ids or group_id required' }, status: :unprocessable_entity
        end

        if templates.empty?
          return render json: { error: 'No templates found' }, status: :not_found
        end

        count = templates.count
        states = templates.pluck(:state_code).compact
        templates.update_all(is_deleted: true, updated_at: Time.current)

        render json: {
          deleted_count: count,
          deleted_states: states,
          message: "Deleted #{count} template(s): #{states.join(', ')}"
        }
      end

      private

      US_STATE_CODES = {
        'AL' => 'Alabama', 'AK' => 'Alaska', 'AZ' => 'Arizona', 'AR' => 'Arkansas',
        'CA' => 'California', 'CO' => 'Colorado', 'CT' => 'Connecticut', 'DE' => 'Delaware',
        'FL' => 'Florida', 'GA' => 'Georgia', 'HI' => 'Hawaii', 'ID' => 'Idaho',
        'IL' => 'Illinois', 'IN' => 'Indiana', 'IA' => 'Iowa', 'KS' => 'Kansas',
        'KY' => 'Kentucky', 'LA' => 'Louisiana', 'ME' => 'Maine', 'MD' => 'Maryland',
        'MA' => 'Massachusetts', 'MI' => 'Michigan', 'MN' => 'Minnesota', 'MS' => 'Mississippi',
        'MO' => 'Missouri', 'MT' => 'Montana', 'NE' => 'Nebraska', 'NV' => 'Nevada',
        'NH' => 'New Hampshire', 'NJ' => 'New Jersey', 'NM' => 'New Mexico', 'NY' => 'New York',
        'NC' => 'North Carolina', 'ND' => 'North Dakota', 'OH' => 'Ohio', 'OK' => 'Oklahoma',
        'OR' => 'Oregon', 'PA' => 'Pennsylvania', 'RI' => 'Rhode Island', 'SC' => 'South Carolina',
        'SD' => 'South Dakota', 'TN' => 'Tennessee', 'TX' => 'Texas', 'UT' => 'Utah',
        'VT' => 'Vermont', 'VA' => 'Virginia', 'WA' => 'Washington', 'WV' => 'West Virginia',
        'WI' => 'Wisconsin', 'WY' => 'Wyoming', 'DC' => 'District of Columbia'
      }.freeze

      def set_template
        # Platform admins can access any non-deleted template (including draft platform templates)
        if current_user&.role.in?(%w[platform_admin tenant super_admin])
          @template = AgreementTemplate.where(is_deleted: false).find(params[:id])
        else
          @template = AgreementTemplate.available_for_company(@company).find(params[:id])
        end
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
          is_master: template.is_master?,
          template_group_id: template.template_group_id,
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

      def multi_state_template_params
        permitted = params.require(:template).permit(
          :name, :description, :template_type, :form_type, :form_number,
          :document_url, :content, :page_count, :agreement_category_id
        )

        raw = params[:template].respond_to?(:to_unsafe_h) ? params[:template].to_unsafe_h : params[:template].to_h

        permitted[:field_placements] = raw[:field_placements] if raw[:field_placements].present?
        permitted[:merge_field_placements] = raw[:merge_field_placements] if raw[:merge_field_placements].present?
        permitted[:custom_field_definitions] = raw[:custom_field_definitions] if raw[:custom_field_definitions].present?
        permitted[:default_signers] = raw[:default_signers] if raw[:default_signers].present?
        permitted[:document_urls] = raw[:document_urls] if raw[:document_urls].present?

        permitted
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
