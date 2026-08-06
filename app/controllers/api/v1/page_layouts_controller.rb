# frozen_string_literal: true

module Api
  module V1
    class PageLayoutsController < ApplicationController
      before_action :set_company_scope

      # GET /api/v1/page_layouts/:module_name
      def show
        return unless authorize_action!('company_settings', 'read')

        layout = find_or_create_layout(params[:module_name])
        reconcile_custom_fields(layout)

        render json: {
          page_layout: page_layout_json(layout)
        }
      end

      # PATCH /api/v1/page_layouts/:module_name
      def update
        return unless authorize_action!('company_settings', 'update')

        layout = find_or_create_layout(params[:module_name])
        layout.updated_by_id = current_user&.id

        layout_data = params[:layout_data]
        if layout_data.is_a?(ActionController::Parameters)
          layout_data = layout_data.to_unsafe_h
        end

        # Enforce protected fields cannot be hidden
        protected_keys = PageLayout::PROTECTED_FIELDS[params[:module_name]] || []
        if protected_keys.any? && layout_data.present? && layout_data['sections'].is_a?(Array)
          layout_data['sections'].each do |section|
            next unless section['fields'].is_a?(Array)
            section['fields'].each do |field|
              if protected_keys.include?(field['key'])
                field['visible'] = true
              end
            end
          end
        end

        if layout.update(layout_data: layout_data)
          render json: { page_layout: page_layout_json(layout) }
        else
          render json: { error: 'Validation failed', details: layout.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/page_layouts/:module_name/reset
      def reset
        return unless authorize_action!('company_settings', 'update')

        layout = find_or_create_layout(params[:module_name])
        layout.updated_by_id = current_user&.id
        default_data = PageLayout.default_layout_for(params[:module_name])

        if layout.update(layout_data: default_data)
          render json: { page_layout: page_layout_json(layout), message: 'Layout reset to default' }
        else
          render json: { error: 'Reset failed', details: layout.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/page_layouts/:module_name/field_definitions
      def field_definitions
        return unless authorize_action!('company_settings', 'read')

        module_name = params[:module_name]
        standard = standard_field_definitions(module_name)
        standard = apply_option_overrides(standard, module_name)
        custom = custom_field_definitions(module_name)
        # Merge per-company tooltip overrides onto BOTH standard and custom
        # field defs so the read-only lead detail (which uses DynamicFormSection
        # → def.description as the InfoHint) shows the same text the admin
        # entered in Company Settings > Field Tooltips or via the gear editor.
        merged = apply_tooltip_overrides(standard + custom, module_name)

        render json: {
          field_definitions: merged,
          meta: {
            module: module_name,
            standard_count: standard.size,
            custom_count: custom.size,
            total: standard.size + custom.size
          }
        }
      end

      # GET /api/v1/page_layouts/:module_name/field_option_overrides
      def field_option_overrides
        return unless authorize_action!('company_settings', 'read')

        overrides = @company.field_option_overrides.for_module(params[:module_name])

        render json: {
          overrides: overrides.map { |o|
            { field_key: o.field_key, options: o.options, updated_at: o.updated_at&.iso8601 }
          }
        }
      end

      # PUT /api/v1/page_layouts/:module_name/field_option_overrides/:field_key
      def update_field_option_override
        return unless authorize_action!('company_settings', 'update')

        options = params[:options]
        return render(json: { error: 'Options must be an array' }, status: :unprocessable_entity) unless options.is_a?(Array)

        # Refuse to override options on fields whose values are constrained by
        # model-level validations (listing_type, status, discount_type, etc.).
        field_def = standard_field_definitions(params[:module_name]).find { |f| f[:key] == params[:field_key] }
        if field_def && field_def[:options_locked]
          return render(json: { error: "\"#{field_def[:label]}\" options are managed by the system and can't be customized" }, status: :unprocessable_entity)
        end

        override = @company.field_option_overrides.find_or_initialize_by(
          module_name: params[:module_name],
          field_key: params[:field_key]
        )
        override.options = options.map(&:to_s).reject(&:blank?)

        if override.save
          render json: { field_key: override.field_key, options: override.options, updated_at: override.updated_at&.iso8601 }
        else
          render json: { errors: override.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/page_layouts/:module_name/field_option_overrides/:field_key
      def delete_field_option_override
        return unless authorize_action!('company_settings', 'update')

        override = @company.field_option_overrides.find_by(
          module_name: params[:module_name],
          field_key: params[:field_key]
        )

        if override
          override.destroy
          render json: { message: 'Reset to defaults' }
        else
          render json: { message: 'No override found' }, status: :not_found
        end
      end

      private

      # Industry label resolver — pulls the company's resolved labels (per-industry
      # defaults merged with company overrides) so field labels follow the same
      # vocabulary as the rest of the app. MH => "Home", RV => "Unit", etc.
      def industry_labels
        @industry_labels ||= (@company.respond_to?(:resolved_labels) ? @company.resolved_labels : {}) || {}
      end

      # Look up a single label key with a fallback. Title-cases nothing — the
      # stored label values are already display-ready (e.g. "Home", "Unit").
      def ilabel(key, fallback)
        industry_labels[key.to_s].presence || fallback
      end

      # Merge company-specific option overrides into standard field definitions
      def apply_option_overrides(fields, module_name)
        # Fetch all overrides for this module in one query
        overrides = @company.field_option_overrides.for_module(module_name).index_by(&:field_key)
        return fields if overrides.empty?

        fields.map do |field|
          override = overrides[field[:key]]
          # Fields with backend enum/inclusion constraints can't accept custom
          # values — silently ignore any override rather than surface bogus
          # picks that would 500 or silently no-op on save.
          if override && !field[:options_locked]
            field.merge(options: override.options, options_customized: true)
          else
            field
          end
        end
      end

      # Merge per-company tooltip overrides (from Company#field_tooltip_overrides)
      # into the `description` slot on each field def. An override wins over any
      # shipped default (standard fields) or CustomField#description (custom
      # fields); missing keys leave the def alone.
      def apply_tooltip_overrides(fields, module_name)
        module_overrides = @company.field_tooltip_overrides[module_name.to_s] || {}
        return fields if module_overrides.empty?

        fields.map do |field|
          override_text = module_overrides[field[:key].to_s]
          if override_text.present?
            field.merge(description: override_text)
          else
            field
          end
        end
      end

      # Self-heals layouts that place a custom field the company no longer has,
      # or that disagree with the field about whether it's required. Runs on
      # read so an admin doesn't have to notice the problem and re-save the
      # layout to clear it.
      def reconcile_custom_fields(layout)
        required_by_key = @company.custom_fields.active
                                  .where(module: layout.custom_field_modules)
                                  .pluck(:field_key, :required)
                                  .to_h { |key, required| [key, !!required] }

        standard_keys = standard_field_definitions(layout.module_name).map { |f| f[:key] }
        result = layout.reconcile_custom_fields!(required_by_key, standard_keys: standard_keys)
        return if result[:removed].empty? && result[:updated].empty?

        Rails.logger.info(
          "[page_layouts] Reconciled company #{@company.id} #{layout.module_name} layout. " \
          "removed: #{result[:removed].join(', ').presence || 'none'}, " \
          "required synced: #{result[:updated].join(', ').presence || 'none'}"
        )
      rescue => e
        Rails.logger.warn("[page_layouts] Reconcile failed for layout #{layout.id}: #{e.message}")
      end

      def find_or_create_layout(module_name)
        layout = @company.page_layouts.for_module(module_name).find_by(layout_type: 'detail')

        unless layout
          layout = @company.page_layouts.create!(
            module_name: module_name,
            layout_type: 'detail',
            layout_data: PageLayout.default_layout_for(module_name),
            is_default: true,
            created_by_id: current_user&.id
          )
        end

        layout
      end

      def page_layout_json(layout)
        {
          id: layout.id,
          moduleName: layout.module_name,
          layoutType: layout.layout_type,
          layoutData: layout.layout_data,
          isDefault: layout.is_default,
          createdAt: layout.created_at&.iso8601,
          updatedAt: layout.updated_at&.iso8601
        }
      end

      def standard_field_definitions(module_name)
        case module_name
        when 'leads'
          leads_standard_fields
        when 'accounts'
          accounts_standard_fields
        when 'contacts'
          contacts_standard_fields
        when 'deals'
          deals_standard_fields
        when 'inventory'
          inventory_standard_fields
        when 'inventory_rv'
          inventory_standard_fields.reject { |f| mh_only_field_keys.include?(f[:key]) }.map do |f|
            f[:key] == 'make' ? f.merge(options: default_rv_makes) : f
          end
        when 'inventory_mh'
          inventory_standard_fields.reject { |f| rv_only_field_keys.include?(f[:key]) }
        when 'contractors'
          contractors_standard_fields
        when 'service_tickets'
          service_tickets_standard_fields
        else
          []
        end
      end

      def service_tickets_standard_fields
        protected_keys = PageLayout::PROTECTED_FIELDS['service_tickets'] || []
        prot = ->(key) { protected_keys.include?(key) }

        [
          { key: 'ticket_number', label: 'Ticket #', type: 'text', source: 'standard', required: false, protected: false, read_only: true },
          { key: 'title', label: 'Service Title', type: 'text', source: 'standard', required: true, protected: prot.call('title') },
          { key: 'description', label: 'Description', type: 'longtext', source: 'standard', required: true, protected: prot.call('description') },
          { key: 'status', label: 'Status', type: 'select', source: 'standard', required: true, protected: prot.call('status'),
            options: %w[pending_review open in_progress waiting_on_manufacturer waiting_parts completed cancelled] },
          { key: 'priority', label: 'Priority', type: 'select', source: 'standard', required: true, protected: prot.call('priority'),
            options: %w[low medium high urgent] },
          { key: 'account_id', label: ilabel('account', 'Account'), type: 'number', source: 'standard', required: false, protected: false },
          { key: 'contact_id', label: 'Contact', type: 'number', source: 'standard', required: false, protected: false },
          { key: 'vehicle_id', label: ilabel('vehicle', 'Home'), type: 'number', source: 'standard', required: false, protected: false },
          { key: 'home_info', label: 'Home Make / Model', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'deal_id', label: 'Deal', type: 'number', source: 'standard', required: false, protected: false },
          { key: 'factory_po', label: 'Factory PO', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'assigned_to', label: 'Assigned To', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'scheduled_date', label: 'Scheduled Date', type: 'date', source: 'standard', required: false, protected: false },
          { key: 'completed_date', label: 'Completed Date', type: 'date', source: 'standard', required: false, protected: false },
          { key: 'notes', label: 'Notes', type: 'longtext', source: 'standard', required: false, protected: false },
          { key: 'portal_notes', label: 'Customer Comments (Portal)', type: 'longtext', source: 'standard', required: false, protected: false, read_only: true },
          { key: 'dealer_only', label: 'Internal Dealer-Only Ticket', type: 'checkbox', source: 'standard', required: false, protected: prot.call('dealer_only') },
          { key: 'portal_visible', label: 'Visible to Customer in Portal', type: 'checkbox', source: 'standard', required: false, protected: prot.call('portal_visible') },
          # Read-only: these are set by the mark-warranty flow, which also
          # creates the draft claim and captures the manufacturer. Toggling them
          # inline would leave a ticket flagged warranty with no claim behind it.
          { key: 'is_warranty_suspected', label: 'Warranty Suspected', type: 'checkbox', source: 'standard', required: false, protected: prot.call('is_warranty_suspected'), read_only: true },
          { key: 'is_warranty_confirmed', label: 'Warranty Confirmed', type: 'checkbox', source: 'standard', required: false, protected: prot.call('is_warranty_confirmed'), read_only: true },
          { key: 'created_at', label: 'Created', type: 'date', source: 'standard', required: false, protected: false, read_only: true },
          { key: 'scheduled_time', label: 'Scheduled Time', type: 'text', source: 'standard', required: false, protected: false, read_only: true },
          { key: 'estimated_hours', label: 'Estimated Hours', type: 'number', source: 'standard', required: false, protected: false, read_only: true },
          { key: 'actual_hours', label: 'Actual Hours', type: 'number', source: 'standard', required: false, protected: false, read_only: true }
        ]
      end

      def contractors_standard_fields
        protected_keys = PageLayout::PROTECTED_FIELDS['contractors'] || []
        [
          { key: 'name', label: 'Company Name', type: 'text', source: 'standard', required: true, protected: protected_keys.include?('name') },
          { key: 'contact_name', label: 'Contact Name', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'email', label: 'Email', type: 'email', source: 'standard', required: false, protected: false },
          { key: 'phone', label: 'Phone', type: 'phone', source: 'standard', required: false, protected: false },
          { key: 'trade_type', label: 'Trade Type', type: 'select', source: 'standard', required: false, protected: false,
            options: %w[general electrical plumbing hvac foundation transport skirting roofing other] },
          { key: 'status', label: 'Status', type: 'select', source: 'standard', required: false, protected: false,
            options: %w[active inactive suspended] },
          { key: 'hourly_rate', label: 'Hourly Rate', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'rating', label: 'Rating', type: 'number', source: 'standard', required: false, protected: false },
          { key: 'license_number', label: 'License Number', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'license_state', label: 'License State', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'license_expiry', label: 'License Expiry', type: 'date', source: 'standard', required: false, protected: false },
          { key: 'insurance_provider', label: 'Insurance Provider', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'insurance_policy_number', label: 'Insurance Policy Number', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'insurance_expiry', label: 'Insurance Expiry', type: 'date', source: 'standard', required: false, protected: false },
          { key: 'bonded', label: 'Bonded', type: 'boolean', source: 'standard', required: false, protected: false },
          { key: 'bond_amount', label: 'Bond Amount', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'bond_expiry', label: 'Bond Expiry', type: 'date', source: 'standard', required: false, protected: false },
          { key: 'notes', label: 'Notes', type: 'longtext', source: 'standard', required: false, protected: false }
        ]
      end

      def rv_only_field_keys
        %w[
          rv_class rv_type body_style mileage mileage_unit fuel_type transmission
          engine_make engine_type vehicle_interior_type number_of_doors seating_capacity
          slide_outs slideouts awning awnings num_air_conditioners leveling_jacks
          self_contained solar_panels backup_camera satellite_tv
          fresh_water_capacity gray_water_capacity black_water_capacity propane_capacity
          dry_weight gross_weight hitch_weight cargo_capacity
          generator generator_make generator_hours generator_fuel_type
        ]
      end

      def default_mh_makes
        %w[Cavco Champion Clayton] + ['Deer Valley', 'Destiny', 'Fairmont', 'Fleetwood',
          'Friendship', 'Homes of Merit', 'Kit', 'Legacy', 'Liberty', 'Live Oak',
          'Marlette', 'Nobility', 'Oakwood', 'Palm Harbor', 'Redman', 'Schult',
          'Skyline', 'Southern Energy', 'Sunshine', 'TRU']
      end

      def default_rv_makes
        ['Coachmen', 'Cruiser RV', 'Dutchmen', 'Fleetwood', 'Forest River',
         'Grand Design', 'Gulf Stream', 'Heartland', 'Holiday Rambler', 'Jayco',
         'Keystone', 'KZ', 'Lance', 'Newmar', 'Northwood', 'Palomino',
         'Prime Time', 'Thor', 'Tiffin', 'Winnebago']
      end

      def mh_only_field_keys
        %w[
          home_type dwelling_type bedrooms bathrooms square_feet sections
          width1 length1 width2 length2 width3 length3
          foundation_type roof_type roof_material siding_type exterior_material
          flooring_type insulation_type ceiling_type wall_type
          heating_type cooling_type water_heater_type master_bedroom_location
          fireplace central_air deck patio garage carport has_storage
          thermopane gutters shutters cathedral_ceiling ceiling_fan skylight
          walkin_closet laundry_room pantry sun_room basement garden_tub
          refrigerator microwave oven dishwasher garbage_disposal
          clothes_washer clothes_dryer
        ]
      end

      def deals_standard_fields
        protected_keys = PageLayout::PROTECTED_FIELDS['deals'] || []
        [
          { key: 'deal_number', label: 'Deal Number', type: 'text', source: 'standard', required: false, protected: true },
          { key: 'name', label: 'Deal Name', type: 'text', source: 'standard', required: true, protected: protected_keys.include?('name') },
          { key: 'customer_name', label: 'Customer Name', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'value', label: 'Deal Value', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'stage', label: 'Stage', type: 'select', source: 'standard', required: false, protected: false,
            options: deals_stage_options, option_labels: deals_stage_option_labels },
          { key: 'probability', label: 'Probability (%)', type: 'percent', source: 'standard', required: false, protected: false },
          { key: 'expected_close_date', label: 'Expected Close Date', type: 'date', source: 'standard', required: false, protected: false },
          { key: 'actual_close_date', label: 'Actual Close Date', type: 'date', source: 'standard', required: false, protected: false },
          { key: 'delivery_date', label: 'Delivery Date', type: 'date', source: 'standard', required: false, protected: false },
          { key: 'deal_type', label: 'Deal Type', type: 'select', source: 'standard', required: false, protected: false,
            options: %w[new used rental rent_to_own consignment] },
          { key: 'vertical', label: 'Vertical', type: 'select', source: 'standard', required: false, protected: false,
            options: %w[rv manufactured_home other] },
          # Source is the company Sources relationship (source_id), edited via the dedicated
          # SourcePicker on the deal form/detail — not an inline-editable layout field. The old
          # free-text 'lead_source' field was removed in favor of it.
          { key: 'owner_id', label: 'Owner / Sales Rep', type: 'user', source: 'standard', required: false, protected: false },
          { key: 'created_at', label: 'Date Created', type: 'date', source: 'standard', required: false, protected: true },
          { key: 'quantity', label: 'Quantity', type: 'number', source: 'standard', required: false, protected: false },
          # Note: source_id, account_id, contact_id, vehicle_id are relationship/lookup fields
          # managed via DealForm only — not supported as inline-editable layout fields
          # Billing Address
          { key: 'billing_street', label: 'Billing Street', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'billing_city', label: 'Billing City', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'billing_state', label: 'Billing State', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'billing_zip', label: 'Billing Zip', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'billing_country', label: 'Billing Country', type: 'text', source: 'standard', required: false, protected: false },
          # Delivery Address
          { key: 'delivery_street', label: 'Delivery Street', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'delivery_city', label: 'Delivery City', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'delivery_state', label: 'Delivery State', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'delivery_zip', label: 'Delivery Zip', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'delivery_country', label: 'Delivery Country', type: 'text', source: 'standard', required: false, protected: false },
          # Economics
          { key: 'selling_price', label: 'Selling Price', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'unit_cost', label: 'Unit Cost', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'trade_allowance', label: 'Trade Allowance', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'trade_payoff', label: 'Trade Payoff', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'accessories_total', label: 'Accessories Total', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'doc_fee', label: 'Doc Fee', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'delivery_fee', label: 'Delivery Fee', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'setup_fee', label: 'Setup Fee', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'skirting_fee', label: 'Skirting Fee', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'down_payment', label: 'Deposit', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'down_payment_due_date', label: 'Deposit Due Date', type: 'date', source: 'standard', required: false, protected: false },
          # Text
          { key: 'win_reason', label: 'Win Reason', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'loss_reason', label: 'Loss Reason', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'competitor', label: 'Competitor', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'description', label: 'Description', type: 'longtext', source: 'standard', required: false, protected: false },
          { key: 'notes', label: 'Notes', type: 'longtext', source: 'standard', required: false, protected: false }
        ]
      end

      def accounts_standard_fields
        protected_keys = PageLayout::PROTECTED_FIELDS['accounts'] || []
        [
          { key: 'name', label: 'Name', type: 'text', source: 'standard', required: true, protected: protected_keys.include?('name') },
          { key: 'email', label: 'Email', type: 'email', source: 'standard', required: false, protected: protected_keys.include?('email') },
          { key: 'phone', label: 'Phone', type: 'phone', source: 'standard', required: false, protected: protected_keys.include?('phone') },
          { key: 'account_type', label: 'Account Type', type: 'select', source: 'standard', required: false, protected: false,
            options: %w[prospect customer partner vendor other] },
          { key: 'status', label: 'Status', type: 'select', source: 'standard', required: false, protected: false,
            options: %w[active inactive suspended] },
          { key: 'rating', label: 'Rating', type: 'select', source: 'standard', required: false, protected: false,
            options: %w[hot warm cold] },
          { key: 'website', label: 'Website', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'industry', label: 'Industry', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'ownership', label: 'Ownership', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'annual_revenue', label: 'Annual Revenue', type: 'number', source: 'standard', required: false, protected: false },
          { key: 'employee_count', label: 'Employee Count', type: 'number', source: 'standard', required: false, protected: false },
          { key: 'source_id', label: 'Source', type: 'select', source: 'standard', required: false, protected: false,
            options: Source.for_company(@company.id).order(:name).pluck(:name) },
          { key: 'owner_id', label: 'Owner', type: 'user', source: 'standard', required: false, protected: false },
          { key: 'billing_street', label: 'Billing Street', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'billing_city', label: 'Billing City', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'billing_state', label: 'Billing State', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'billing_postal_code', label: 'Billing Postal Code', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'billing_country', label: 'Billing Country', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'shipping_street', label: 'Shipping Street', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'shipping_city', label: 'Shipping City', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'shipping_state', label: 'Shipping State', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'shipping_postal_code', label: 'Shipping Postal Code', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'shipping_country', label: 'Shipping Country', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'deposit_amount', label: 'Deposit', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'description', label: 'Description', type: 'longtext', source: 'standard', required: false, protected: false },
          { key: 'notes', label: 'Notes', type: 'longtext', source: 'standard', required: false, protected: false }
        ]
      end

      def contacts_standard_fields
        protected_keys = PageLayout::PROTECTED_FIELDS['contacts'] || []
        [
          { key: 'first_name', label: 'First Name', type: 'text', source: 'standard', required: true, protected: protected_keys.include?('first_name') },
          { key: 'last_name', label: 'Last Name', type: 'text', source: 'standard', required: true, protected: protected_keys.include?('last_name') },
          { key: 'email', label: 'Email', type: 'email', source: 'standard', required: true, protected: protected_keys.include?('email') },
          { key: 'phone', label: 'Phone', type: 'phone', source: 'standard', required: false, protected: protected_keys.include?('phone') },
          { key: 'title', label: 'Job Title', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'department', label: 'Department', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'company_name', label: 'Company Name', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'account_id', label: 'Account', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'owner_id', label: 'Owner', type: 'user', source: 'standard', required: false, protected: false },
          { key: 'is_primary', label: 'Primary Contact', type: 'boolean', source: 'standard', required: false, protected: false },
          { key: 'street', label: 'Street', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'city', label: 'City', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'state', label: 'State', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'zip', label: 'Zip', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'country', label: 'Country', type: 'text', source: 'standard', required: false, protected: false },
          # Delivery Address
          { key: 'delivery_street', label: 'Delivery Street', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'delivery_city', label: 'Delivery City', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'delivery_state', label: 'Delivery State', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'delivery_zip', label: 'Delivery Zip', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'delivery_country', label: 'Delivery Country', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'opt_out_email', label: 'Opt Out Email', type: 'boolean', source: 'standard', required: false, protected: false },
          { key: 'opt_out_sms', label: 'Opt Out SMS', type: 'boolean', source: 'standard', required: false, protected: false },
          # Inventory preferences
          { key: 'preferred_bedrooms', label: 'Preferred Bedrooms', type: 'select', source: 'standard', required: false, protected: false,
            options: ['1', '2', '3', '4', '5', '6+'] },
          { key: 'preferred_bathrooms', label: 'Preferred Bathrooms', type: 'select', source: 'standard', required: false, protected: false,
            options: ['1', '1.5', '2', '2.5', '3', '3+'] },
          { key: 'preferred_min_sqft', label: 'Min Square Feet', type: 'number', source: 'standard', required: false, protected: false },
          { key: 'preferred_max_sqft', label: 'Max Square Feet', type: 'number', source: 'standard', required: false, protected: false },
          { key: 'preferred_home_type', label: 'Preferred Home Type', type: 'select', source: 'standard', required: false, protected: false,
            options: ['manufactured', 'rv', 'tiny_home', 'modular'] },
          { key: 'budget_range', label: 'Budget Range', type: 'select', source: 'standard', required: false, protected: false,
            options: ['Under $50k', '$50k-$100k', '$100k-$150k', '$150k-$200k', '$200k-$300k', '$300k+'] },
          { key: 'preferred_vehicle_id', label: "Interested #{ilabel('vehicle', 'Home')}", type: 'vehicle', source: 'standard', required: false, protected: false },
          { key: 'deposit_amount', label: 'Deposit', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'notes', label: 'Notes', type: 'longtext', source: 'standard', required: false, protected: false }
        ]
      end

      # Builds the "status" field definition for the leads page layout from
      # the tenant's configured lead_statuses. Preserves display order
      # (sort_order asc) and includes both active + excluded statuses so a
      # lead currently in a dead-end status ("Closed Lost", etc.) can still
      # be re-picked. Inactive-only statuses are excluded — they're
      # intentionally hidden from new pickers.
      LEGACY_LEAD_STATUS_FALLBACK = %w[
        new not_contacted attempted_to_contact contact_in_future contacted
        engaged pre_qualified qualified showing_scheduled proposal negotiation
        application_submitted closed_won closed_lost lost_lead not_qualified
        junk_lead
      ].freeze

      def leads_status_field_definition
        rows = @company&.lead_statuses&.active&.ordered&.to_a || []
        if rows.any?
          options = rows.map(&:key)
          option_labels = rows.each_with_object({}) { |r, h| h[r.key] = r.label }
          {
            key: 'status', label: 'Status', type: 'select', source: 'standard',
            required: false, protected: false,
            options: options, option_labels: option_labels
          }
        else
          # Defensive fallback — the seed migration guarantees every company
          # has statuses, but if that's somehow missing, don't ship an empty
          # dropdown.
          {
            key: 'status', label: 'Status', type: 'select', source: 'standard',
            required: false, protected: false,
            options: LEGACY_LEAD_STATUS_FALLBACK,
            option_labels: LEGACY_LEAD_STATUS_FALLBACK.each_with_object({}) { |k, h| h[k] = k.humanize }
          }
        end
      end

      def leads_standard_fields
        protected_keys = PageLayout::PROTECTED_FIELDS['leads'] || []
        [
          { key: 'first_name', label: 'First Name', type: 'text', source: 'standard', required: true, protected: true },
          { key: 'last_name', label: 'Last Name', type: 'text', source: 'standard', required: true, protected: true },
          { key: 'email', label: 'Email', type: 'email', source: 'standard', required: true, protected: true },
          { key: 'phone', label: 'Phone', type: 'phone', source: 'standard', required: true, protected: true },
          # Co-applicant (co-borrower) — becomes a second contact on conversion
          { key: 'co_applicant_first_name', label: 'Co-Applicant First Name', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'co_applicant_last_name', label: 'Co-Applicant Last Name', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'co_applicant_email', label: 'Co-Applicant Email', type: 'email', source: 'standard', required: false, protected: false },
          { key: 'co_applicant_phone', label: 'Co-Applicant Phone', type: 'phone', source: 'standard', required: false, protected: false },
          { key: 'company_name', label: 'Company Name', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'title', label: 'Job Title', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'created_at', label: 'Lead Created', type: 'datetime', source: 'standard', required: false, protected: false },
          # Status options come from the tenant's configurable lead_statuses
          # table (CRM → Lead Statuses), NOT a hardcoded enum. Any status the
          # dealer adds in the manager surfaces here on the very next fetch,
          # in the exact sort_order the manager displays. Falls back to the
          # legacy hardcoded list if the tenant somehow has no configured
          # statuses (defensive — the seed migration creates 17 defaults per
          # company so this shouldn't happen in practice).
          leads_status_field_definition,
          { key: 'owner_id', label: 'Owner', type: 'user', source: 'standard', required: false, protected: false },
          { key: 'source_id', label: 'Source', type: 'select', source: 'standard', required: false, protected: false,
            options: Source.for_company(@company.id).order(:name).pluck(:name) },
          { key: 'budget_range', label: 'Budget Range', type: 'select', source: 'standard', required: false, protected: false,
            options: ['Under $50k', '$50k-$100k', '$100k-$150k', '$150k-$200k', '$200k+'] },
          { key: 'purchase_timeframe', label: 'Purchase Timeframe', type: 'select', source: 'standard', required: false, protected: false,
            options: ['Immediate', '1-3 months', '3-6 months', '6-12 months', '12+ months'] },
          { key: 'rv_experience', label: 'RV Experience', type: 'select', source: 'standard', required: false, protected: false,
            options: ['First Time Buyer', 'Some Experience', 'Experienced', 'Very Experienced'] },
          { key: 'vehicle_id', label: "Interested #{ilabel('vehicle', 'Home')}", type: 'vehicle_picker', source: 'standard', required: false, protected: false },
          { key: 'preferred_bedrooms', label: 'Preferred Bedrooms', type: 'select', source: 'standard', required: false, protected: false,
            options: ['1', '2', '3', '4', '5', '6+'] },
          { key: 'preferred_bathrooms', label: 'Preferred Bathrooms', type: 'select', source: 'standard', required: false, protected: false,
            options: ['1', '1.5', '2', '2.5', '3', '3+'] },
          { key: 'preferred_min_sqft', label: 'Min Square Feet', type: 'number', source: 'standard', required: false, protected: false },
          { key: 'preferred_max_sqft', label: 'Max Square Feet', type: 'number', source: 'standard', required: false, protected: false },
          { key: 'preferred_home_type', label: 'Preferred Home Type', type: 'select', source: 'standard', required: false, protected: false,
            options: ['manufactured', 'rv', 'tiny_home', 'modular'] },
          { key: 'deposit_amount', label: 'Deposit', type: 'currency', source: 'standard', required: false, protected: false },
          { key: 'interests_requirements', label: 'Interests/Requirements', type: 'longtext', source: 'standard', required: false, protected: false },
          { key: 'notes', label: 'Notes', type: 'longtext', source: 'standard', required: false, protected: false },
          # Address
          { key: 'street', label: 'Street', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'city', label: 'City', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'state', label: 'State', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'zip', label: 'Zip', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'country', label: 'Country', type: 'text', source: 'standard', required: false, protected: false }
        ]
      end

      def inventory_standard_fields
        protected_keys = PageLayout::PROTECTED_FIELDS['inventory'] || []
        [
          # Basic Information
          { key: 'inventory_id', label: 'Stock #', type: 'text', source: 'standard', required: false, protected: protected_keys.include?('inventory_id'), visibility: 'both' },
          { key: 'year', label: 'Year', type: 'number', source: 'standard', required: true, protected: protected_keys.include?('year'), visibility: 'both' },
          { key: 'make', label: 'Make', type: 'select', source: 'standard', required: true, protected: protected_keys.include?('make'), visibility: 'both',
            options: default_mh_makes },
          { key: 'model', label: 'Model', type: 'text', source: 'standard', required: true, protected: protected_keys.include?('model'), visibility: 'both' },
          { key: 'trim', label: 'Trim', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'listing_type', label: 'Listing Type', type: 'select', source: 'standard', required: true, protected: protected_keys.include?('listing_type'), visibility: 'both',
            options: %w[rv manufactured_home], options_locked: true },
          { key: 'status', label: 'Status', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: %w[available reserved sold pending], options_locked: true },
          { key: 'condition', label: 'Condition', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: %w[new used certified refurbished] },
          { key: 'color', label: 'Color', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'vin', label: 'VIN', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'serial_number', label: 'Serial Number', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'date_in_stock', label: 'Date In Stock', type: 'date', source: 'standard', required: false, protected: false, visibility: 'internal' },
          { key: 'date_sold', label: 'Date Sold', type: 'date', source: 'standard', required: false, protected: false, visibility: 'internal' },

          # Pricing (external)
          { key: 'msrp', label: 'Base Sale Price', type: 'currency', source: 'standard', required: false, protected: true, visibility: 'both', description: 'The home’s selling price before packages and add-ons. This is what the customer pays for the base home — add-ons build on top of it. Not a cost.' },
          { key: 'sale_price', label: 'Sale Price (Legacy)', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'internal', description: 'Legacy field — use Base Sale Price instead' },
          { key: 'special_discount_enabled', label: 'Special Discount', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both', description: 'Enable a special discounted price for this unit' },
          { key: 'discount_type', label: 'Discount Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both', options: ['% of Home Price', '$ Flat Amount', '% of Total w/ Packages'], options_locked: true, description: '% of Home Price, flat $ off, or % of Total (Home Price + packages)' },
          { key: 'discount_value', label: 'Discount Value', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both', description: 'Enter percentage or dollar amount' },
          { key: 'discounted_price', label: 'Discounted Price', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'both', description: 'Calculated sale price after discount is applied' },
          { key: 'rent_price', label: 'Rent Price', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'rent_to_own_price', label: 'Rent-to-Own Price', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'deposit_amount', label: 'Deposit Amount', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'lot_rent', label: 'Lot Rent', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'utilities', label: 'Utilities', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'both' },

          # Cost Details (internal only) — the dealer's LANDED cost that drives gross profit
          # and commissions (structured_cost = total_cost OR dealer_cost+freight_cost+pdi_cost).
          # Distinct from the manufacturer invoice (Invoice / Cost Basis card, lender Max
          # Advance only) and from any buyer-facing delivery fee (a deal line item).
          # NOTE: the legacy `cost` field is intentionally NOT exposed here — it was a duplicate
          # of the landed cost and is retired. The column still exists in the DB (read-only,
          # mirrored from structured_cost in the serializer) but is no longer an editable field,
          # so it can't be placed on a layout or dragged in via the Page Layout Editor.
          { key: 'dealer_cost', label: 'Home Cost', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'internal', description: 'Your acquisition cost for the home — the cost basis for gross profit and commissions. If a manufacturer invoice is captured and Home Cost is blank, it is seeded from the invoice total as a starting point; OVERRIDE it here if the invoice is not your true cost. The invoice itself (Invoice / Cost Basis card) drives the lender Max Advance separately.' },
          { key: 'freight_cost', label: 'Freight Cost', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'internal', description: 'What YOU pay to deliver the home to the lot. Part of your landed cost for gross profit. Different from the manufacturer freight on the invoice (used for lender Max Advance) and from any delivery fee you charge the buyer (a deal line item).' },
          { key: 'pdi_cost', label: 'PDI Cost', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'internal', description: 'Pre-delivery inspection / prep cost. Part of your landed cost for gross profit.' },
          { key: 'total_cost', label: 'Total Cost', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'internal', description: 'Overrides the sum of Home + Freight + PDI when set. Leave blank to use the components. This is the cost basis for gross profit and commissions.' },
          { key: 'holdback_amount', label: 'Holdback Amount', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'internal', description: 'Dealer holdback. Not a cost — excluded from COGS and gross profit.' },
          { key: 'floor_plan_rate', label: 'Floor Plan Rate', type: 'percent', source: 'standard', required: false, protected: false, visibility: 'internal' },
          { key: 'target_gross', label: 'Target Gross', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'internal', description: 'Your gross-profit goal for this unit. A pricing guardrail — not used in cost or Max Advance calculations.' },
          { key: 'minimum_price', label: 'Minimum Price', type: 'currency', source: 'standard', required: false, protected: false, visibility: 'internal', description: 'Lowest acceptable selling price. A pricing guardrail — not used in cost or Max Advance calculations.' },

          # RV Specifications
          { key: 'rv_class', label: 'RV Class', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Class A', 'Class B', 'Class C', 'Fifth Wheel', 'Travel Trailer', 'Toy Hauler', 'Pop-Up', 'Truck Camper', 'Park Model'] },
          { key: 'rv_type', label: 'RV Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Motorhome', 'Travel Trailer', 'Fifth Wheel', 'Toy Hauler', 'Pop-up', 'Truck Camper'] },
          { key: 'body_style', label: 'Body Style', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Class A Motorhome', 'Class B Motorhome', 'Class C Motorhome', 'Travel Trailer', 'Fifth Wheel', 'Toy Hauler', 'Pop-up Camper', 'Truck Camper', 'Park Model', 'Destination Trailer', 'Hybrid Trailer', 'Teardrop Trailer'] },
          { key: 'mileage', label: 'Mileage', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'mileage_unit', label: 'Mileage Unit', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: %w[SMI KMI miles kilometers hours] },
          { key: 'fuel_type', label: 'Fuel Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Gasoline', 'Diesel', 'Electric', 'Hybrid', 'Propane'] },
          { key: 'transmission', label: 'Transmission', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Automatic', 'Manual', 'CVT', '6-Speed Automatic', '8-Speed Automatic', '10-Speed Automatic'] },
          { key: 'engine_make', label: 'Engine Make', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'engine_type', label: 'Engine Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['V6', 'V8', 'V10', 'I4', 'I6', 'Diesel', 'Other'] },
          { key: 'exterior_color', label: 'Exterior Color', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'interior_color', label: 'Interior Color', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'vehicle_interior_type', label: 'Interior Type', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'number_of_doors', label: 'Doors', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'seating_capacity', label: 'Seating Capacity', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'sleeps', label: 'Sleeps', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'sleeping_capacity', label: 'Sleeping Capacity', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'slide_outs', label: 'Slide Outs', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'slideouts', label: 'Slideouts (RVT)', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'awning', label: 'Awning', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'awnings', label: 'Awnings Count', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'num_air_conditioners', label: 'Air Conditioners', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'leveling_jacks', label: 'Leveling Jacks', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'self_contained', label: 'Self Contained', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'solar_panels', label: 'Solar Panels', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'backup_camera', label: 'Backup Camera', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'satellite_tv', label: 'Satellite TV', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },

          # MH Specifications
          { key: 'home_type', label: 'Home Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Double Wide', 'Manufactured Home', 'Mobile Home', 'Modular Home', 'Park Model', 'Single Wide', 'Tiny Home', 'Triple Wide'] },
          { key: 'dwelling_type', label: 'Dwelling Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Single Wide', 'Double Wide', 'Triple Wide', 'Modular Home', 'Park Model', 'Tiny Home', 'Manufactured Home', 'Mobile Home'] },
          { key: 'bedrooms', label: 'Bedrooms', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'bathrooms', label: 'Bathrooms', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'square_feet', label: 'Square Feet', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'sections', label: 'Sections', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'length', label: 'Length (ft)', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'width', label: 'Width (ft)', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'weight', label: 'Weight (lbs)', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'width1', label: 'Section 1 Width', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'length1', label: 'Section 1 Length', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'width2', label: 'Section 2 Width', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'length2', label: 'Section 2 Length', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'width3', label: 'Section 3 Width', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'length3', label: 'Section 3 Length', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'foundation_type', label: 'Foundation Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Slab', 'Pier', 'Crawl Space', 'Basement', 'Permanent', 'Concrete Runners', 'Skirted'] },
          { key: 'roof_type', label: 'Roof Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Gable', 'Hip', 'Flat', 'Shed', 'Mansard', 'Gambrel'] },
          { key: 'roof_material', label: 'Roof Material', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Asphalt Shingles', 'Metal Roofing', 'TPO', 'EPDM', 'Built-up Roofing', 'Tile'] },
          { key: 'siding_type', label: 'Siding Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Vinyl', 'Fiber Cement', 'Wood', 'Metal', 'Brick', 'Stone', 'Stucco', 'Composite', 'Hardboard'] },
          { key: 'exterior_material', label: 'Exterior Material', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Vinyl Siding', 'Fiber Cement', 'Wood Siding', 'Metal Siding', 'Brick', 'Stone', 'Stucco', 'Composite'] },
          { key: 'flooring_type', label: 'Flooring Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Carpet', 'Vinyl Plank', 'Laminate', 'Hardwood', 'Tile', 'Linoleum', 'Concrete'] },
          { key: 'insulation_type', label: 'Insulation Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Fiberglass', 'Foam Board', 'Spray Foam', 'Cellulose', 'Mineral Wool', 'Reflective'] },
          { key: 'ceiling_type', label: 'Ceiling Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Flat', 'Vaulted', 'Cathedral', 'Tray', 'Coffered', 'Beamed'] },
          { key: 'wall_type', label: 'Wall Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Drywall', 'Vinyl Over Gypsum (VOG)', 'Wood Paneling', 'Plaster', 'Tongue and Groove'] },
          { key: 'heating_type', label: 'Heating Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Forced Air', 'Heat Pump', 'Electric Baseboard', 'Radiant', 'Geothermal', 'Propane', 'Natural Gas', 'Wood Stove'] },
          { key: 'cooling_type', label: 'Cooling Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Central Air', 'Heat Pump', 'Window Units', 'Mini-Split', 'Evaporative', 'None'] },
          { key: 'water_heater_type', label: 'Water Heater Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Electric', 'Gas', 'Propane', 'Tankless', 'Heat Pump', 'Solar'] },
          { key: 'master_bedroom_location', label: 'Master Bedroom Location', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Front', 'Rear', 'Center', 'Split (Master + Guest separated)'] },

          # Water & Tanks
          { key: 'fresh_water_capacity', label: 'Fresh Water (gal)', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'gray_water_capacity', label: 'Gray Water (gal)', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'black_water_capacity', label: 'Black Water (gal)', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'propane_capacity', label: 'Propane (gal)', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },

          # Weights
          { key: 'dry_weight', label: 'Dry Weight (lbs)', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'gross_weight', label: 'Gross Weight (lbs)', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'hitch_weight', label: 'Hitch Weight (lbs)', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'cargo_capacity', label: 'Cargo Capacity (lbs)', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },

          # Generator
          { key: 'generator', label: 'Has Generator', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'generator_make', label: 'Generator Make', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'generator_hours', label: 'Generator Hours', type: 'number', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'generator_fuel_type', label: 'Generator Fuel Type', type: 'select', source: 'standard', required: false, protected: false, visibility: 'both',
            options: ['Gas', 'Diesel', 'Propane'] },

          # MH Amenities (booleans)
          { key: 'fireplace', label: 'Fireplace', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'central_air', label: 'Central Air', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'deck', label: 'Deck', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'patio', label: 'Patio', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'garage', label: 'Garage', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'carport', label: 'Carport', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'has_storage', label: 'Storage', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'thermopane', label: 'Thermopane Windows', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'gutters', label: 'Gutters', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'shutters', label: 'Shutters', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'cathedral_ceiling', label: 'Cathedral Ceiling', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'ceiling_fan', label: 'Ceiling Fan', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'skylight', label: 'Skylight', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'walkin_closet', label: 'Walk-in Closet', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'laundry_room', label: 'Laundry Room', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'pantry', label: 'Pantry', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'sun_room', label: 'Sun Room', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'basement', label: 'Basement', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'garden_tub', label: 'Garden Tub', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },

          # MH Appliances (booleans)
          { key: 'refrigerator', label: 'Refrigerator', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'microwave', label: 'Microwave', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'oven', label: 'Oven', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'dishwasher', label: 'Dishwasher', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'garbage_disposal', label: 'Garbage Disposal', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'clothes_washer', label: 'Clothes Washer', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'clothes_dryer', label: 'Clothes Dryer', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'both' },

          # Features & Description
          { key: 'description', label: 'Description', type: 'longtext', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'special_features', label: 'Special Features', type: 'longtext', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'notes', label: 'Internal Notes', type: 'longtext', source: 'standard', required: false, protected: false, visibility: 'internal' },
          { key: 'terms', label: 'Terms', type: 'longtext', source: 'standard', required: false, protected: false, visibility: 'both' },

          # Location & Address
          { key: 'address1', label: 'Address', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'address2', label: 'Address 2', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'location_city', label: 'City', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'location_state', label: 'State', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'location_zip', label: 'ZIP', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'county_name', label: 'County', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'community_name', label: 'Community', type: 'text', source: 'standard', required: false, protected: false, visibility: 'both' },

          # Seller Info (internal)
          { key: 'seller_name', label: 'Seller Name', type: 'text', source: 'standard', required: false, protected: false, visibility: 'internal' },
          { key: 'seller_phone', label: 'Seller Phone', type: 'phone', source: 'standard', required: false, protected: false, visibility: 'internal' },
          { key: 'seller_address_street', label: 'Seller Street', type: 'text', source: 'standard', required: false, protected: false, visibility: 'internal' },
          { key: 'seller_address_city', label: 'Seller City', type: 'text', source: 'standard', required: false, protected: false, visibility: 'internal' },
          { key: 'seller_address_state', label: 'Seller State', type: 'text', source: 'standard', required: false, protected: false, visibility: 'internal' },
          { key: 'seller_address_zip', label: 'Seller ZIP', type: 'text', source: 'standard', required: false, protected: false, visibility: 'internal' },

          # Media
          { key: 'overlay_text', label: 'Overlay Text', type: 'text', source: 'standard', required: false, protected: false, visibility: 'internal' },
          { key: 'video_url', label: 'Video URL', type: 'url', source: 'standard', required: false, protected: false, visibility: 'both' },
          { key: 'virtual_tour_url', label: 'Virtual Tour URL', type: 'url', source: 'standard', required: false, protected: false, visibility: 'both' },

          # Other flags
          { key: 'sale_pending', label: 'Sale Pending', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'internal' },
          { key: 'repo', label: 'Repo', type: 'checkbox', source: 'standard', required: false, protected: false, visibility: 'internal' }
        ]
      end

      def deals_stage_options
        saved = Setting.get('Company', @company.id, 'pipeline_stages', nil)
        if saved.is_a?(Array) && saved.any?
          saved.sort_by { |s| s['order'] || s[:order] || 0 }.map { |s| s['key'] || s[:key] }
        else
          %w[prospecting qualification needs_analysis proposal negotiation closed_won closed_lost]
        end
      end

      def deals_stage_option_labels
        saved = Setting.get('Company', @company.id, 'pipeline_stages', nil)
        if saved.is_a?(Array) && saved.any?
          saved.each_with_object({}) { |s, h| h[s['key'] || s[:key]] = s['name'] || s[:name] }
        else
          {
            'prospecting' => 'Prospecting', 'qualification' => 'Qualification',
            'needs_analysis' => 'Needs Analysis', 'proposal' => 'Proposal',
            'negotiation' => 'Negotiation', 'closed_won' => 'Closed Won', 'closed_lost' => 'Closed Lost'
          }
        end
      end

      def custom_field_definitions(module_name)
        @company.custom_fields.active.for_module(module_name).ordered.map do |field|
          {
            id: field.id,
            key: field.field_key,
            label: field.label || field.name,
            type: field.field_type,
            source: 'custom',
            required: field.required || false,
            protected: false,
            options: field.options,
            placeholder: field.placeholder,
            # description is used as the hover tooltip on the form
            # (FieldLabel component reads it). Without this the NewLeadForm's
            # renderCustomField was getting undefined and never showed the ⓘ.
            description: field.description,
            section: field.section,
            visibility: field.visibility || 'internal'
          }
        end
      end
    end
  end
end
