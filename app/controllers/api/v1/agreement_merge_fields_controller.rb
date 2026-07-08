module Api
  module V1
    class AgreementMergeFieldsController < ApplicationController
      before_action :set_company_scope
      before_action :load_entities

      # GET /api/v1/agreement_merge_fields
      def index
        return unless authorize_action!('agreements', 'read')

        render json: {
          merge_fields: decorate_with_source_metadata(merge_field_definitions),
          line_item_values: flattened_line_item_values,
          line_item_counts: line_item_counts,
        }
      end

      private

      def load_entities
        @contact = nil
        @account = nil
        @deal = nil

        begin
          @contact = @company.contacts.find_by(id: params[:contact_id]) if params[:contact_id].present?
        rescue => e
          Rails.logger.error("[AgreementMergeFields] Contact lookup failed: #{e.message}")
        end

        begin
          @account = @company.accounts.find_by(id: params[:account_id]) if params[:account_id].present?
        rescue => e
          Rails.logger.error("[AgreementMergeFields] Account lookup failed: #{e.message}")
        end

        begin
          @deal = @company.deals.find_by(id: params[:deal_id]) if params[:deal_id].present?
        rescue => e
          Rails.logger.error("[AgreementMergeFields] Deal lookup failed: #{e.message}")
        end

        begin
          if @deal.present?
            @vehicle = nil
            if @deal.respond_to?(:vehicle_id) && @deal.vehicle_id.present?
              @vehicle = @company.vehicles.find_by(id: @deal.vehicle_id)
            end
            if @vehicle.nil?
              vehicle_product = @deal.deal_products
                                    .where.not(product_id: nil)
                                    .first
              if vehicle_product&.product_id.present?
                @vehicle = @company.vehicles.find_by(id: vehicle_product.product_id)
              end
            end
          end
        rescue => e
          Rails.logger.error("[AgreementMergeFields] Vehicle lookup failed: #{e.message}")
        end

        begin
          if params[:invoice_id].present?
            @invoice = @company.invoices.find_by(id: params[:invoice_id])
          elsif @deal.present?
            # Auto-detect invoice with draw schedule from linked deal
            @invoice = @company.invoices.where(deal_id: @deal.id)
                                        .where.not(draw_schedule: [nil, {}])
                                        .order(created_at: :desc).first
            @invoice ||= @company.invoices.where(deal_id: @deal.id).order(created_at: :desc).first
          end
        rescue => e
          Rails.logger.error("[AgreementMergeFields] Invoice lookup failed: #{e.message}")
        end
      end

      # Flattens deal line items to indexed keys (deal.line_items[0].description, ...)
      # so the AgreementBuilder preview + Fill Form step can resolve the same keys
      # that LineItemsTablePlacer generates for insert-table placements.
      # Uses the same service that PDF generation uses — single source of truth.
      def flattened_line_item_values
        return {} unless @deal
        values = {}
        ::Agreements::LineItemValuesFlattener.apply!(values, @deal)
        values
      end

      # Actual per-array line-item counts so the frontend can skip overflow rows
      # (template has 12 rows but the deal only has 5 line items → hide rows 6-12).
      def line_item_counts
        return {} unless @deal
        all_items = ::Agreements::DealLineItemsResolver.call(@deal)
        ::Agreements::LineItemValuesFlattener
          .build_arrays_by_key(all_items)
          .transform_values(&:length)
      end

      def merge_field_definitions
        {
          contact: {
            available: @contact.present?,
            fields: [
              { key: 'contact.first_name', label: 'First Name', type: 'text', value: @contact&.first_name },
              { key: 'contact.last_name', label: 'Last Name', type: 'text', value: @contact&.last_name },
              { key: 'contact.full_name', label: 'Full Name', type: 'text', value: @contact ? [@contact.first_name, @contact.last_name].compact.join(' ').presence : nil },
              { key: 'contact.email', label: 'Email', type: 'text', value: @contact&.email },
              { key: 'contact.phone', label: 'Phone', type: 'text', value: @contact&.phone },
              { key: 'contact.mobile_phone', label: 'Mobile / Cell Phone', type: 'text', value: @contact.try(:mobile_phone) || @contact.try(:cell_phone) },
              { key: 'contact.title', label: 'Title', type: 'text', value: @contact.try(:title) },
              { key: 'contact.department', label: 'Department', type: 'text', value: @contact.try(:department) },
              { key: 'contact.company_name', label: 'Company Name', type: 'text', value: @contact ? (@contact.try(:company_name).presence || @contact.account&.name) : nil },
              # Mailing address
              { key: 'contact.street', label: 'Street Address', type: 'text', value: @contact.try(:street) },
              { key: 'contact.city', label: 'City', type: 'text', value: @contact.try(:city) },
              { key: 'contact.state', label: 'State', type: 'text', value: @contact.try(:state) },
              { key: 'contact.zip', label: 'ZIP Code', type: 'text', value: @contact.try(:zip) },
              { key: 'contact.country', label: 'Country', type: 'text', value: @contact.try(:country) },
              { key: 'contact.full_address', label: 'Full Address', type: 'text', value: @contact ? [@contact.try(:street), @contact.try(:city), @contact.try(:state), @contact.try(:zip)].compact.join(', ').presence : nil },
              # Delivery address
              { key: 'contact.delivery_street', label: 'Delivery Street', type: 'text', value: @contact.try(:delivery_street) },
              { key: 'contact.delivery_city', label: 'Delivery City', type: 'text', value: @contact.try(:delivery_city) },
              { key: 'contact.delivery_state', label: 'Delivery State', type: 'text', value: @contact.try(:delivery_state) },
              { key: 'contact.delivery_zip', label: 'Delivery ZIP', type: 'text', value: @contact.try(:delivery_zip) },
              { key: 'contact.delivery_country', label: 'Delivery Country', type: 'text', value: @contact.try(:delivery_country) },
              { key: 'contact.full_delivery_address', label: 'Full Delivery Address', type: 'text', value: @contact ? [@contact.try(:delivery_street), @contact.try(:delivery_city), @contact.try(:delivery_state), @contact.try(:delivery_zip)].compact.join(', ').presence : nil },
            ] + build_entity_custom_fields(@contact, 'contact')
          },
          account: {
            available: @account.present?,
            fields: [
              { key: 'account.name', label: 'Account Name', type: 'text', value: @account&.name },
              { key: 'account.account_number', label: 'Account Number', type: 'text', value: @account.try(:account_number) },
              { key: 'account.account_type', label: 'Account Type', type: 'text', value: @account.try(:account_type)&.titleize },
              { key: 'account.email', label: 'Account Email', type: 'text', value: @account.try(:email) },
              { key: 'account.phone', label: 'Account Phone', type: 'text', value: @account.try(:phone) },
              { key: 'account.website', label: 'Website', type: 'text', value: @account.try(:website) },
              { key: 'account.industry', label: 'Industry', type: 'text', value: @account.try(:industry) },
              { key: 'account.rating', label: 'Rating', type: 'text', value: @account.try(:rating) },
              { key: 'account.ownership', label: 'Ownership', type: 'text', value: @account.try(:ownership) },
              { key: 'account.annual_revenue', label: 'Annual Revenue', type: 'currency', value: @account.try(:annual_revenue) },
              { key: 'account.employee_count', label: 'Employee Count', type: 'text', value: @account.try(:employee_count)&.to_s },
              # Billing address
              { key: 'account.billing_street', label: 'Billing Street', type: 'text', value: @account.try(:billing_street) },
              { key: 'account.billing_city', label: 'Billing City', type: 'text', value: @account.try(:billing_city) },
              { key: 'account.billing_state', label: 'Billing State', type: 'text', value: @account.try(:billing_state) },
              { key: 'account.billing_zip', label: 'Billing ZIP', type: 'text', value: @account.try(:billing_postal_code) },
              { key: 'account.billing_country', label: 'Billing Country', type: 'text', value: @account.try(:billing_country) },
              { key: 'account.full_billing_address', label: 'Full Billing Address', type: 'text', value: @account ? [@account.try(:billing_street), @account.try(:billing_city), @account.try(:billing_state), @account.try(:billing_postal_code)].compact.join(', ').presence : nil },
              # Shipping address
              { key: 'account.shipping_street', label: 'Shipping Street', type: 'text', value: @account.try(:shipping_street) },
              { key: 'account.shipping_city', label: 'Shipping City', type: 'text', value: @account.try(:shipping_city) },
              { key: 'account.shipping_state', label: 'Shipping State', type: 'text', value: @account.try(:shipping_state) },
              { key: 'account.shipping_zip', label: 'Shipping ZIP', type: 'text', value: @account.try(:shipping_postal_code) },
              { key: 'account.shipping_country', label: 'Shipping Country', type: 'text', value: @account.try(:shipping_country) },
              { key: 'account.full_shipping_address', label: 'Full Shipping Address', type: 'text', value: @account ? [@account.try(:shipping_street), @account.try(:shipping_city), @account.try(:shipping_state), @account.try(:shipping_postal_code)].compact.join(', ').presence : nil },
            ] + build_entity_custom_fields(@account, 'account')
          },
          deal: {
            available: @deal.present?,
            fields: [
              { key: 'deal.name', label: 'Deal Name', type: 'text', value: @deal ? (@deal.respond_to?(:title) ? @deal.title : @deal.name) : nil },
              { key: 'deal.deal_number', label: 'Deal Number', type: 'text', value: @deal&.deal_number },
              { key: 'deal.amount', label: 'Deal Amount', type: 'currency', value: @deal ? (@deal.respond_to?(:amount) ? @deal.amount : @deal.try(:value)) : nil },
              { key: 'deal.selling_price', label: 'Selling Price', type: 'currency', value: @deal&.selling_price },
              { key: 'deal.unit_cost', label: 'Unit Cost', type: 'currency', value: @deal&.unit_cost },
              { key: 'deal.trade_allowance', label: 'Trade-In Allowance', type: 'currency', value: @deal&.trade_allowance },
              { key: 'deal.trade_payoff', label: 'Trade Payoff', type: 'currency', value: @deal&.trade_payoff },
              # Phase 3 removed standalone fee columns from the Deal UI — fees now live
              # as line items (category:'fee'). Use deal.fee_total or the deal.line_items_fee
              # array below to surface them. `deal.stage` follows.
              { key: 'deal.stage', label: 'Deal Stage', type: 'text', value: @deal.respond_to?(:stage) ? @deal.stage : nil },
              { key: 'deal.close_date', label: 'Expected Close Date', type: 'date', value: @deal ? (@deal.respond_to?(:expected_close_date) ? @deal.expected_close_date : @deal.try(:close_date)) : nil },
              { key: 'deal.delivery_date', label: 'Delivery Date', type: 'date', value: @deal&.delivery_date },
              { key: 'deal.deal_type', label: 'Deal Type', type: 'text', value: @deal&.deal_type },
              { key: 'deal.probability', label: 'Probability', type: 'text', value: @deal.respond_to?(:probability) ? @deal.probability : nil },
              { key: 'deal.owner_name', label: 'Sales Person', type: 'text', value: @deal ? (@deal.respond_to?(:owner) ? [@deal.owner&.first_name, @deal.owner&.last_name].compact.join(' ').presence : @deal.try(:assigned_to_name)) : nil },
              { key: 'deal.customer_name', label: 'Customer Name', type: 'text', value: @deal&.customer_name },
              { key: 'deal.delivery_street', label: 'Delivery Address', type: 'text', value: @deal&.delivery_street },
              { key: 'deal.delivery_city', label: 'Delivery City', type: 'text', value: @deal&.delivery_city },
              { key: 'deal.delivery_state', label: 'Delivery State', type: 'text', value: @deal&.delivery_state },
              { key: 'deal.delivery_zip', label: 'Delivery ZIP', type: 'text', value: @deal&.delivery_zip },
              { key: 'deal.billing_street', label: 'Billing Address', type: 'text', value: @deal&.billing_street },
              { key: 'deal.billing_city', label: 'Billing City', type: 'text', value: @deal&.billing_city },
              { key: 'deal.billing_state', label: 'Billing State', type: 'text', value: @deal&.billing_state },
              { key: 'deal.billing_zip', label: 'Billing ZIP', type: 'text', value: @deal&.billing_zip },
              { key: 'deal.dealer_discount', label: 'Dealer Discount', type: 'currency', value: @deal.try(:dealer_discount) },
              { key: 'deal.sales_event_discount', label: 'Sales Event Discount', type: 'currency', value: @deal.try(:sales_event_discount) },
              { key: 'deal.manager_discount', label: 'Manager Discount', type: 'currency', value: @deal.try(:manager_discount) },
              { key: 'deal.preferred_payment_discount', label: 'Preferred Payment Discount', type: 'currency', value: @deal.try(:preferred_payment_discount) },
              { key: 'deal.multi_unit_discount', label: 'Multi-Unit Discount', type: 'currency', value: @deal.try(:multi_unit_discount) },
              # deal.subtotal_1 / subtotal_2 removed — no longer on the DealForm.
              { key: 'deal.tax_amount', label: 'Tax Amount', type: 'currency', value: @deal.try(:tax_amount) },
              { key: 'deal.total_amount', label: 'Total Amount', type: 'currency', value: @deal.try(:total_amount) },
              { key: 'deal.down_payment', label: 'Down Payment', type: 'currency', value: @deal.try(:down_payment) },
              { key: 'deal.additional_payment', label: 'Additional Payment', type: 'currency', value: @deal.try(:additional_payment) },
              { key: 'deal.unpaid_balance', label: 'Unpaid Balance', type: 'currency', value: @deal.try(:unpaid_balance) },
              # deal.addendum_items / deal.addendum_total removed — superseded by
              # deal.line_items and deal.line_items_total below.

              # ── Deal line items (from the selected desk scenario) ────────────────
              # These read from deal_desk_scenarios.line_items JSONB — the same rows the
              # rep sees in the Deal Edit UI's Line Items card. See
              # Agreements::DealLineItemsResolver for shape + home-identification rules.
              { key: 'deal.line_items', label: 'All Line Items (repeating)', type: 'line_items', value: deal_line_items_data },
              { key: 'deal.home_line_item', label: 'Home Line Item', type: 'line_item', value: home_line_item_data },
              { key: 'deal.non_home_line_items', label: 'Non-Home Line Items (repeating)', type: 'line_items', value: non_home_line_items_data },
              { key: 'deal.line_items_home', label: 'Home-Tagged Line Items (repeating)', type: 'line_items', value: line_items_by_category('home') },
              { key: 'deal.line_items_land', label: 'Land / Site Improvement Line Items (repeating)', type: 'line_items', value: line_items_by_category('land') },
              { key: 'deal.line_items_fee', label: 'Fee Line Items (repeating)', type: 'line_items', value: line_items_by_category('fee') },
              { key: 'deal.line_items_accessory', label: 'Accessory Line Items (repeating)', type: 'line_items', value: line_items_by_category('accessory') },
              { key: 'deal.line_items_service', label: 'Service Line Items (repeating)', type: 'line_items', value: line_items_by_category('service') },
              { key: 'deal.line_items_product', label: 'Product Line Items (repeating)', type: 'line_items', value: line_items_by_category('product') },
              { key: 'deal.line_items_other', label: 'Other Line Items (repeating)', type: 'line_items', value: line_items_by_category('other') },

              # ── Per-category subtotals ────────────────────────────────────────────
              { key: 'deal.home_total', label: 'Home Line Total', type: 'currency', value: line_items_subtotal { |li| li[:is_home] } },
              { key: 'deal.non_home_line_items_total', label: 'Non-Home Line Items Subtotal', type: 'currency', value: line_items_subtotal { |li| !li[:is_home] } },
              { key: 'deal.line_items_total', label: 'All Line Items Subtotal', type: 'currency', value: line_items_subtotal { |_li| true } },
              { key: 'deal.land_total', label: 'Land / Site Improvements Subtotal', type: 'currency', value: line_items_subtotal { |li| li[:category] == 'land' } },
              { key: 'deal.fee_total', label: 'Fees Subtotal', type: 'currency', value: line_items_subtotal { |li| li[:category] == 'fee' } },
              { key: 'deal.accessory_total_from_lines', label: 'Accessories Subtotal (from line items)', type: 'currency', value: line_items_subtotal { |li| li[:category] == 'accessory' } },
              { key: 'deal.service_total', label: 'Services Subtotal', type: 'currency', value: line_items_subtotal { |li| li[:category] == 'service' } },
              { key: 'deal.product_total', label: 'Products Subtotal', type: 'currency', value: line_items_subtotal { |li| li[:category] == 'product' } },
              { key: 'deal.other_total', label: 'Other Subtotal', type: 'currency', value: line_items_subtotal { |li| li[:category] == 'other' } },

              # ── Derived totals commonly needed on PAs ─────────────────────────────
              { key: 'deal.discounted_price', label: 'Discounted Price (Selling − Discounts)', type: 'currency', value: derived_discounted_price },
              { key: 'deal.total_home_price', label: 'Total Home Price (Home + Admin/Doc Fee)', type: 'currency', value: derived_total_home_price },
            ] + build_entity_custom_fields(@deal, 'deal')
          },
          vehicle: {
            available: @vehicle.present?,
            fields: [
              # Core identity
              { key: 'vehicle.make', label: 'Make / Manufacturer', type: 'text', value: @vehicle.try(:make) },
              { key: 'vehicle.model', label: 'Model', type: 'text', value: @vehicle.try(:model) },
              { key: 'vehicle.trim', label: 'Trim', type: 'text', value: @vehicle.try(:trim) },
              { key: 'vehicle.year', label: 'Year', type: 'text', value: @vehicle.try(:year)&.to_s },
              { key: 'vehicle.vin', label: 'VIN', type: 'text', value: @vehicle.try(:vin) },
              { key: 'vehicle.serial_number', label: 'Serial Number', type: 'text', value: @vehicle.try(:serial_number) || @vehicle.try(:vin) },
              { key: 'vehicle.stock_number', label: 'Stock Number', type: 'text', value: @vehicle.try(:stock_number) },
              { key: 'vehicle.inventory_id', label: 'Inventory ID', type: 'text', value: @vehicle.try(:inventory_id) },
              { key: 'vehicle.condition', label: 'New/Used', type: 'text', value: @vehicle.try(:condition)&.titleize },
              { key: 'vehicle.status', label: 'Status', type: 'text', value: @vehicle.try(:status)&.titleize },
              # Dimensions & layout
              { key: 'vehicle.sections', label: 'Sections (Single/Double)', type: 'text', value: @vehicle.try(:sections)&.to_s },
              { key: 'vehicle.bedrooms', label: 'Bedrooms', type: 'text', value: @vehicle.try(:bedrooms)&.to_s },
              { key: 'vehicle.bathrooms', label: 'Bathrooms', type: 'text', value: @vehicle.try(:bathrooms)&.to_s },
              { key: 'vehicle.length', label: 'Length', type: 'text', value: @vehicle.try(:length)&.to_s },
              { key: 'vehicle.width', label: 'Width', type: 'text', value: @vehicle.try(:width)&.to_s },
              { key: 'vehicle.floor_size', label: 'Floor Size (L x W)', type: 'text', value: @vehicle ? [[@vehicle.try(:length), @vehicle.try(:width)].compact.join(' x ')].reject(&:blank?).first : nil },
              { key: 'vehicle.square_feet', label: 'Approx Sq Ft', type: 'text', value: @vehicle.try(:square_feet)&.to_s },
              { key: 'vehicle.sleeps', label: 'Sleeps', type: 'text', value: (@vehicle.try(:sleeps) || @vehicle.try(:sleeping_capacity))&.to_s },
              # Colors & appearance
              { key: 'vehicle.exterior_color', label: 'Exterior Color', type: 'text', value: @vehicle.try(:exterior_color) || @vehicle.try(:color) },
              { key: 'vehicle.interior_color', label: 'Interior Color', type: 'text', value: @vehicle.try(:interior_color) },
              { key: 'vehicle.exterior_material', label: 'Exterior Material / Siding', type: 'text', value: @vehicle.try(:exterior_material) || @vehicle.try(:siding_type) },
              { key: 'vehicle.roof_material', label: 'Roof Material', type: 'text', value: @vehicle.try(:roof_material) || @vehicle.try(:roof_type) },
              # Home type & construction
              { key: 'vehicle.home_type', label: 'Home Type', type: 'text', value: @vehicle.try(:home_type) },
              { key: 'vehicle.dwelling_type', label: 'Dwelling Type', type: 'text', value: @vehicle.try(:dwelling_type) },
              { key: 'vehicle.body_style', label: 'Body Style', type: 'text', value: @vehicle.try(:body_style) },
              { key: 'vehicle.foundation_type', label: 'Foundation Type', type: 'text', value: @vehicle.try(:foundation_type) },
              # Insulation
              { key: 'vehicle.insulation_r_roof', label: 'Roof Insulation R-Value', type: 'text', value: @vehicle.try(:insulation_r_roof) },
              { key: 'vehicle.insulation_r_wall', label: 'Wall Insulation R-Value', type: 'text', value: @vehicle.try(:insulation_r_wall) },
              { key: 'vehicle.insulation_r_floor', label: 'Floor Insulation R-Value', type: 'text', value: @vehicle.try(:insulation_r_floor) },
              { key: 'vehicle.insulation_type', label: 'Insulation Type', type: 'text', value: @vehicle.try(:insulation_type) },
              { key: 'vehicle.floor_joist_size', label: 'Floor Joist Size', type: 'text', value: @vehicle.try(:floor_joist_size) },
              { key: 'vehicle.electrical_service', label: 'Electrical Service', type: 'text', value: @vehicle.try(:electrical_service) },
              # Interior features
              { key: 'vehicle.flooring_type', label: 'Flooring Type', type: 'text', value: @vehicle.try(:flooring_type) },
              { key: 'vehicle.heating_type', label: 'Heating Type', type: 'text', value: @vehicle.try(:heating_type) },
              { key: 'vehicle.cooling_type', label: 'Cooling Type', type: 'text', value: @vehicle.try(:cooling_type) },
              { key: 'vehicle.water_heater_type', label: 'Water Heater Type', type: 'text', value: @vehicle.try(:water_heater_type) },
              { key: 'vehicle.ceiling_type', label: 'Ceiling Type', type: 'text', value: @vehicle.try(:ceiling_type) },
              { key: 'vehicle.wall_type', label: 'Wall Type', type: 'text', value: @vehicle.try(:wall_type) },
              { key: 'vehicle.master_bedroom_location', label: 'Master Bedroom Location', type: 'text', value: @vehicle.try(:master_bedroom_location) },
              # Appliances (booleans → Yes/No)
              { key: 'vehicle.refrigerator', label: 'Refrigerator', type: 'text', value: @vehicle.try(:refrigerator) == true ? 'Yes' : (@vehicle.try(:refrigerator) == false ? 'No' : nil) },
              { key: 'vehicle.dishwasher', label: 'Dishwasher', type: 'text', value: @vehicle.try(:dishwasher) == true ? 'Yes' : (@vehicle.try(:dishwasher) == false ? 'No' : nil) },
              { key: 'vehicle.microwave', label: 'Microwave', type: 'text', value: @vehicle.try(:microwave) == true ? 'Yes' : (@vehicle.try(:microwave) == false ? 'No' : nil) },
              { key: 'vehicle.oven', label: 'Oven / Range', type: 'text', value: @vehicle.try(:oven) == true ? 'Yes' : (@vehicle.try(:oven) == false ? 'No' : nil) },
              { key: 'vehicle.garbage_disposal', label: 'Garbage Disposal', type: 'text', value: @vehicle.try(:garbage_disposal) == true ? 'Yes' : (@vehicle.try(:garbage_disposal) == false ? 'No' : nil) },
              { key: 'vehicle.clothes_washer', label: 'Clothes Washer', type: 'text', value: @vehicle.try(:clothes_washer) == true ? 'Yes' : (@vehicle.try(:clothes_washer) == false ? 'No' : nil) },
              { key: 'vehicle.clothes_dryer', label: 'Clothes Dryer', type: 'text', value: @vehicle.try(:clothes_dryer) == true ? 'Yes' : (@vehicle.try(:clothes_dryer) == false ? 'No' : nil) },
              { key: 'vehicle.fireplace', label: 'Fireplace', type: 'text', value: @vehicle.try(:fireplace) == true ? 'Yes' : (@vehicle.try(:fireplace) == false ? 'No' : nil) },
              { key: 'vehicle.central_air', label: 'Central Air', type: 'text', value: @vehicle.try(:central_air) == true ? 'Yes' : (@vehicle.try(:central_air) == false ? 'No' : nil) },
              { key: 'vehicle.garden_tub', label: 'Garden Tub', type: 'text', value: @vehicle.try(:garden_tub) == true ? 'Yes' : (@vehicle.try(:garden_tub) == false ? 'No' : nil) },
              # Pricing
              { key: 'vehicle.msrp', label: 'MSRP', type: 'currency', value: @vehicle.try(:msrp) },
              { key: 'vehicle.sale_price', label: 'Sale Price', type: 'currency', value: @vehicle.try(:sale_price) },
              { key: 'vehicle.cost', label: 'Cost', type: 'currency', value: @vehicle.try(:cost) },
              { key: 'vehicle.dealer_cost', label: 'Dealer Cost', type: 'currency', value: @vehicle.try(:dealer_cost) },
              { key: 'vehicle.freight_cost', label: 'Freight Cost', type: 'currency', value: @vehicle.try(:freight_cost) },
              { key: 'vehicle.total_cost', label: 'Total Cost', type: 'currency', value: @vehicle.try(:total_cost) },
              { key: 'vehicle.minimum_price', label: 'Minimum Price', type: 'currency', value: @vehicle.try(:minimum_price) },
              { key: 'vehicle.deposit_amount', label: 'Deposit Amount', type: 'currency', value: @vehicle.try(:deposit_amount) },
              # Location
              { key: 'vehicle.county_name', label: 'County', type: 'text', value: @vehicle.try(:county_name) },
              { key: 'vehicle.community_name', label: 'Community / Park Name', type: 'text', value: @vehicle.try(:community_name) },
              { key: 'vehicle.lot_rent', label: 'Lot Rent', type: 'currency', value: @vehicle.try(:lot_rent) },
              # RV-specific
              { key: 'vehicle.rv_type', label: 'RV Type', type: 'text', value: @vehicle.try(:rv_type) },
              { key: 'vehicle.rv_class', label: 'RV Class', type: 'text', value: @vehicle.try(:rv_class) },
              { key: 'vehicle.fuel_type', label: 'Fuel Type', type: 'text', value: @vehicle.try(:fuel_type) },
              { key: 'vehicle.transmission', label: 'Transmission', type: 'text', value: @vehicle.try(:transmission) },
              { key: 'vehicle.mileage', label: 'Mileage', type: 'text', value: @vehicle.try(:mileage)&.to_s },
              { key: 'vehicle.weight', label: 'Weight', type: 'text', value: (@vehicle.try(:weight) || @vehicle.try(:dry_weight))&.to_s },
              { key: 'vehicle.gross_weight', label: 'GVWR', type: 'text', value: @vehicle.try(:gross_weight)&.to_s },
              { key: 'vehicle.hitch_weight', label: 'Hitch Weight', type: 'text', value: @vehicle.try(:hitch_weight)&.to_s },
              { key: 'vehicle.slide_outs', label: 'Slide Outs', type: 'text', value: (@vehicle.try(:slide_outs) || @vehicle.try(:slideouts))&.to_s },
            ] + build_entity_custom_fields(@vehicle, 'vehicle')
          },
          invoice: {
            available: @invoice.present?,
            fields: [
              { key: 'invoice.number', label: 'Invoice Number', type: 'text', value: @invoice&.invoice_number },
              { key: 'invoice.date', label: 'Invoice Date', type: 'date', value: @invoice&.invoice_date&.strftime('%m/%d/%Y') },
              { key: 'invoice.due_date', label: 'Due Date', type: 'date', value: @invoice&.due_date&.strftime('%m/%d/%Y') },
              { key: 'invoice.total', label: 'Total', type: 'currency', value: @invoice&.total },
              { key: 'invoice.amount_due', label: 'Amount Due', type: 'currency', value: @invoice&.amount_due },
              { key: 'invoice.draw_schedule_text', label: 'Draw Schedule', type: 'text', value: @invoice ? format_draw_schedule(@invoice) : nil }
            ]
          },
          company: {
            available: true,
            fields: [
              { key: 'company.name', label: 'Company Name', type: 'text', value: @company.name },
              { key: 'company.email', label: 'Company Email', type: 'text', value: @company.respond_to?(:email) ? @company.email : nil },
              { key: 'company.phone', label: 'Company Phone', type: 'text', value: @company.respond_to?(:phone) ? @company.phone : nil },
              { key: 'company.website', label: 'Company Website', type: 'text', value: @company.respond_to?(:website) ? @company.website : nil },
              { key: 'company.address', label: 'Company Address', type: 'text', value: [@company.try(:street), @company.try(:city), @company.try(:state), @company.try(:zip)].compact.join(', ').presence }
            ]
          },
          date: {
            available: true,
            fields: [
              { key: 'date.today', label: "Today's Date", type: 'date', value: Date.today.strftime('%m/%d/%Y') },
              { key: 'date.current_year', label: 'Current Year', type: 'text', value: Date.today.year.to_s },
              { key: 'date.current_month', label: 'Current Month', type: 'text', value: Date.today.strftime('%B') }
            ]
          },
          agreement: {
            available: true,
            fields: [
              { key: 'agreement.number', label: 'Agreement Number', type: 'text', value: nil },
              { key: 'agreement.title', label: 'Title', type: 'text', value: nil },
              { key: 'agreement.date', label: 'Agreement Date', type: 'date', value: nil },
              { key: 'agreement.expiry_date', label: 'Expiry Date', type: 'date', value: nil }
            ]
          },
          signer: {
            available: true,
            fields: [
              { key: 'signer.name', label: 'Signer Name', type: 'text', value: nil },
              { key: 'signer.email', label: 'Signer Email', type: 'text', value: nil },
              { key: 'signer.signature', label: 'Signature', type: 'signature', value: nil },
              { key: 'signer.initials', label: 'Initials', type: 'initials', value: nil },
              { key: 'signer.signed_date', label: 'Date Signed', type: 'date', value: nil }
            ]
          },
          custom: {
            available: true,
            fields: [
              { key: 'custom.text_field', label: 'Custom Text', type: 'text_input', value: nil },
              { key: 'custom.date_field', label: 'Custom Date', type: 'date_input', value: nil },
              { key: 'custom.checkbox', label: 'Custom Checkbox', type: 'checkbox', value: nil }
            ]
          }
        }
      end

      # Memoized normalized line items for @deal (from the selected desk scenario,
      # falling back to deal_products). Returns [] when there is no deal.
      def deal_line_items_data
        return [] unless @deal
        @deal_line_items_data ||= ::Agreements::DealLineItemsResolver.call(@deal)
      end

      # THE home row (source-authoritative). Returns nil when there is no clear home.
      def home_line_item_data
        deal_line_items_data.find { |li| li[:is_home] }
      end

      # Everything but the home row, in position order.
      def non_home_line_items_data
        deal_line_items_data.reject { |li| li[:is_home] }
      end

      # Line items whose `category` field equals the given value. Category alone is
      # user-tagged in the UI and NOT the same as the home identification rule —
      # a row tagged category:'home' without a matching vehicle_id/source is treated
      # as an add-on by the home helpers above, but still appears here.
      def line_items_by_category(cat)
        deal_line_items_data.select { |li| li[:category].to_s == cat.to_s }
      end

      # Subtotal of matching line items (uses line_total = amount * quantity).
      def line_items_subtotal
        return nil unless @deal
        deal_line_items_data.select { |li| yield(li) }.sum { |li| li[:line_total].to_f }.round(2)
      end

      # Selling price minus every discount column the deal exposes.
      def derived_discounted_price
        return nil unless @deal
        base = @deal.selling_price.to_f
        discounts = %i[dealer_discount sales_event_discount manager_discount preferred_payment_discount multi_unit_discount]
                    .sum { |m| @deal.try(m).to_f }
        (base - discounts).round(2)
      end

      # Home price + admin/doc fee — common "Total Home Price" box on purchase agreements.
      # Uses the identified home row's line_total when available, else selling_price.
      def derived_total_home_price
        return nil unless @deal
        home = home_line_item_data
        home_amount = home ? home[:line_total].to_f : @deal.selling_price.to_f
        admin = @deal.try(:effective_doc_fee).to_f
        (home_amount + admin).round(2)
      end

      # Attaches source_section / source_field_id / source_path to every field so the
      # frontend reverse-preview drawer can open to the right place. Unknown keys
      # (dynamic custom fields) get a generic path derived from the entity prefix.
      def decorate_with_source_metadata(groups)
        groups.each do |_group_key, group|
          Array(group[:fields]).each do |field|
            meta = ::Agreements::MergeFieldSourceMetadata.for(field[:key])
            if meta
              field[:source_section]  = meta[:section]
              field[:source_field_id] = meta[:field_id]
              field[:source_path]     = meta[:path]
            else
              # Dynamic custom field (e.g. 'deal.custom.<key>'). Infer a sensible path.
              entity, _rest = field[:key].to_s.split('.', 2)
              field[:source_section]  = "#{entity}_custom_fields"
              field[:source_field_id] = field[:key].to_s.split('.').last
              field[:source_path]     = [entity.to_s.titleize, 'Custom Fields', field[:label].to_s]
            end
          end
        end
        groups
      end

      def build_addendum_items(deal)
        deal.deal_products.order(:created_at).map do |item|
          {
            description: item.product_name || item.notes || 'Item',
            quantity: item.quantity || 1,
            unit_price: item.unit_price.to_f,
            discount: item.discount.to_f,
            total: item.total.to_f,
          }
        end
      rescue => e
        Rails.logger.error("[AgreementMergeFields] build_addendum_items failed: #{e.message}")
        []
      end

      # Generic custom field builder — works for any entity with custom_field_values JSONB column
      def build_entity_custom_fields(entity, prefix)
        return [] unless entity.present? && entity.respond_to?(:custom_field_values) && entity.custom_field_values.present?

        entity.custom_field_values.map do |key, value|
          next if value.nil?
          {
            key: "#{prefix}.custom.#{key}",
            label: key.to_s.titleize,
            type: value.is_a?(Numeric) ? 'currency' : (value.is_a?(TrueClass) || value.is_a?(FalseClass) ? 'checkbox' : 'text'),
            value: value
          }
        end.compact
      rescue => e
        Rails.logger.error("[AgreementMergeFields] build_entity_custom_fields(#{prefix}) failed: #{e.message}")
        []
      end

      def format_draw_schedule(invoice)
        return nil unless invoice.draw_schedule.present? && invoice.draw_schedule['draws'].present?

        draws = invoice.draw_schedule['draws'].sort_by { |d| d['position'] || 0 }
        template_name = invoice.draw_schedule['template_name']
        h = ActionController::Base.helpers

        lines = []
        lines << "Payment Draw Schedule#{template_name.present? ? " (#{template_name})" : ''}"
        lines << "Invoice: #{invoice.invoice_number} | Total: #{h.number_to_currency(invoice.total)}"
        lines << ''

        draws.each_with_index do |draw, i|
          pct = "#{draw['percentage']}%"
          amt = h.number_to_currency(draw['amount'])
          desc = draw['description'] || "Draw #{i + 1}"
          lines << "Draw #{i + 1}: #{pct} - #{desc} - #{amt}"
        end

        lines.join("\n")
      end
    end
  end
end
