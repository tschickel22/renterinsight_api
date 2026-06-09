# frozen_string_literal: true

module Api
  module V1
    class PackageTemplatesController < ApplicationController
      include RbacAuthorization
      rbac_resource :inventory,
        read_actions: [:index],
        create_actions: [:create],
        update_actions: [:update, :reorder],
        delete_actions: [:destroy]

      before_action :set_company_scope
      before_action :set_template, only: [:update, :destroy]

      # GET /api/v1/package_templates
      def index
        templates = @company.package_templates.active.ordered

        # Filter by vehicle type if provided (rv/mh) - also return 'all' templates
        if params[:vehicle_type].present?
          vt = params[:vehicle_type].downcase
          templates = templates.where(applicable_to: [vt, 'all'])
        end

        # Filter by visibility scope: inventory UI only sees 'inventory' + 'all'
        # Deals/invoices/quotes see everything
        if params[:scope].present?
          scope = params[:scope].downcase
          if scope == 'inventory'
            templates = templates.where(visibility_scope: ['inventory', 'all', nil])
          end
          # 'finance' and 'all' scopes see everything — no filter needed
        end

        payload = templates.map { |t| template_json(t) }

        # Standard Items (dealer-installed allowance defaults) — opt-in merge.
        # Line-item pickers (deals/quotes/invoices/inventory) pass
        # include_standard=true to show these alongside templates. The Item
        # Templates management page does NOT pass it, so it never renders rows
        # it can't edit (Standard Items are managed in Finance > Loan Settings).
        # Negative IDs guarantee no collision with real template IDs; inventory
        # apply_template resolves negative IDs back to CompanyAllowanceDefault.
        if params[:include_standard].present?
          payload += @company.company_allowance_defaults.active.ordered.map { |d| standard_item_json(d) }
        end

        render json: payload
      end

      # POST /api/v1/package_templates
      def create
        existing = @company.package_templates.active.where('LOWER(name) = LOWER(?)', template_params[:name]).first
        if existing
          if existing.default_price == template_params[:default_price]&.to_f
            return render json: template_json(existing), status: :ok
          else
            existing.update(template_params.except(:name))
            return render json: template_json(existing), status: :ok
          end
        end

        template = @company.package_templates.build(template_params)
        template.position = @company.package_templates.maximum(:position).to_i + 1

        if template.save
          render json: template_json(template), status: :created
        else
          render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/package_templates/:id
      def update
        if @template.update(template_params)
          render json: template_json(@template)
        else
          render json: { errors: @template.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/package_templates/:id
      def destroy
        @template.update(is_active: false)
        head :no_content
      end

      # POST /api/v1/package_templates/reorder
      def reorder
        ordered_ids = params[:ordered_ids] || []
        ordered_ids.each_with_index do |id, idx|
          @company.package_templates.find_by(id: id)&.update_column(:position, idx)
        end
        render json: { success: true }
      end

      private

      def set_template
        @template = @company.package_templates.find_by(id: params[:id])
        render json: { error: 'Package template not found' }, status: :not_found unless @template
      end

      def template_params
        # Frontend sends camelCase keys - transform to snake_case
        raw = params.require(:package_template).to_unsafe_h
        normalized = raw.transform_keys { |k| k.to_s.underscore }
        ActionController::Parameters.new(normalized).permit(
          :name, :description, :default_price, :cost, :include_in_total, :is_active, :position, :applicable_to, :visibility_scope, :taxable, :tax_rate, :show_price_in_marketing
        )
      end

      def template_json(template)
        {
          id: template.id,
          name: template.name,
          description: template.description,
          defaultPrice: template.default_price&.to_f,
          cost: template.respond_to?(:cost) ? template.cost&.to_f : nil,
          includeInTotal: template.include_in_total,
          position: template.position,
          isActive: template.is_active,
          applicableTo: template.applicable_to || 'all',
          visibilityScope: template.respond_to?(:visibility_scope) ? (template.visibility_scope || 'all') : 'all',
          taxable: template.respond_to?(:taxable) ? (template.taxable || false) : false,
          taxRate: template.respond_to?(:tax_rate) ? template.tax_rate&.to_f : nil,
          showPriceInMarketing: template.respond_to?(:show_price_in_marketing) ? (template.show_price_in_marketing.nil? ? true : template.show_price_in_marketing) : true,
          createdAt: template.created_at,
          updatedAt: template.updated_at
        }
      end

      # CompanyAllowanceDefault shaped as a PackageTemplate for the merged
      # picker feed. Price/cost are the dealer's company-level numbers;
      # standard/max allowances ride along so pickers can hint the caps.
      # The created line item must persist allowanceDefaultId so the Max
      # Advance calculator and lender-cap flagging can identify it later.
      def standard_item_json(d)
        {
          id: -d.id,                                  # negative = standard item namespace
          name: d.name,
          description: d.category.to_s.titleize,
          defaultPrice: d.dealer_price&.to_f,
          cost: d.dealer_cost&.to_f,
          includeInTotal: true,
          position: 10_000 + d.position.to_i,         # group after real templates
          isActive: true,
          applicableTo: 'all',
          visibilityScope: 'all',
          taxable: false,
          taxRate: nil,
          showPriceInMarketing: true,
          isStandardItem: true,
          allowanceDefaultId: d.id,
          standardAllowance: d.standard_allowance&.to_f,
          maximumAllowance: d.maximum_allowance&.to_f,
          createdAt: d.created_at,
          updatedAt: d.updated_at
        }
      end
    end
  end
end
