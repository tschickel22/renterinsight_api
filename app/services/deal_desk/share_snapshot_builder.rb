# frozen_string_literal: true

# Builds the JSON snapshot stored on `DealDeskShare#snapshot`. Runs entirely
# server-side so the client can never leak cost/gross/margin into the shared
# view. What the customer sees is what this service returns — full stop.
#
# The shape is deliberately close to what the frontend's DealDeskPackageView
# expects so no server↔client transformation is needed on the public page.
module DealDesk
  class ShareSnapshotBuilder
    attr_reader :deal, :scenarios, :vehicle_payload

    # @param deal      [Deal]
    # @param scenarios [Array<DealDeskScenario>]
    # @param vehicle_payload [Hash, nil] product of VehicleBrochureJson#vehicle_brochure_payload;
    #        the controller must build it so `request` is in scope for absolute URLs.
    def initialize(deal:, scenarios:, vehicle_payload:)
      @deal = deal
      @scenarios = Array(scenarios)
      @vehicle_payload = vehicle_payload
    end

    def build
      {
        'deal' => deal_summary,
        'vehicle' => vehicle_payload,
        'unit' => unit_summary,           # Same fields the pencil PDF's "The Home" section uses.
        'location' => location_summary,   # Branded selling location (waterfall: scenario → deal).
        'salesperson' => salesperson_summary,
        'scenarios' => scenarios.map { |s| scenario_customer_json(s) },
        'shared_at' => Time.current.iso8601
      }
    end

    private

    def deal_summary
      buyer_name = deal.contact&.full_name.presence || deal.customer_name.presence || ''
      {
        'id' => deal.id,
        'name' => deal.name,
        'customer_name' => buyer_name,
        'company_name' => deal.company&.name
      }
    end

    # Compact vehicle facts for the pencil-style "The Home" section.
    def unit_summary
      unit = scenarios.first&.vehicle || deal.vehicle
      return nil unless unit
      id_val = unit.serial_number.presence ||
               (unit.respond_to?(:vin) ? unit.vin.presence : nil) ||
               unit.stock_number.presence ||
               unit.inventory_id
      {
        'display_name' => [unit.year, unit.make, unit.model].compact.join(' '),
        'id_label' => (unit.respond_to?(:vin) && unit.vin.present?) ? 'VIN' : 'Serial Number',
        'id_value' => id_val,
        'bedrooms' => unit.bedrooms,
        'bathrooms' => unit.bathrooms,
        'square_feet' => (unit.respond_to?(:square_feet) ? unit.square_feet : nil)
      }
    end

    # Location branding used to render the header (logo / address / phone / email).
    # Mirrors QuotePdfGenerator's Location → Company waterfall.
    def location_summary
      loc = scenarios.first&.location || deal.location
      company = deal.company
      branding = if loc
        (Setting.get('Location', loc.id, 'branding') rescue nil) || {}
      else
        {}
      end
      branding = (Setting.get('Company', company.id, 'branding') rescue nil) || {} if branding.blank?

      {
        'name' => loc&.name || company&.name,
        'logo' => branding['logo'].presence,
        'primary_color' => (branding['primaryColor'] || branding['primary_color'] || '#1F4E79').to_s,
        'address_line1' => (loc.respond_to?(:address_line1) ? loc&.address_line1 : nil),
        'address_line2' => (loc.respond_to?(:address_line2) ? loc&.address_line2 : nil),
        'city' => loc&.city,
        'state' => loc&.state,
        'zip' => (loc.respond_to?(:zip_code) ? loc&.zip_code : nil),
        'phone' => loc&.phone,
        'email' => loc&.email
      }
    end

    def salesperson_summary
      rep = deal.respond_to?(:primary_salesperson) ? (deal.primary_salesperson || deal.owner) : deal.owner
      rep ||= scenarios.first&.created_by
      return nil unless rep
      { 'name' => rep.respond_to?(:name) ? rep.name : rep.email, 'email' => rep.email, 'phone' => (rep.respond_to?(:phone) ? rep.phone : nil) }
    end

    # Customer-safe scenario JSON — mirrors `scenario_json` in
    # DealDeskScenariosController but with `can_view_costs?` forced FALSE.
    # Never emit dealer_gross / front_gross / back_gross / unit_cost / per-line cost.
    #
    # Also merges the engine's customer_h projection so page 1 of the package
    # can render EXACTLY the numbers the pencil PDF shows (total_fees, taxes,
    # trade_equity, computed APR/term/payment/OTD).
    def scenario_customer_json(scenario)
      base = {
        'id' => scenario.id,
        'deal_id' => scenario.deal_id,
        'vehicle_id' => scenario.vehicle_id,
        'label' => scenario.label,
        'status' => scenario.status,
        'valid_through' => scenario.valid_through,
        'trade_allowance' => scenario.trade_allowance&.to_f,
        'trade_payoff'    => scenario.trade_payoff&.to_f,
        'cash_down'       => scenario.cash_down&.to_f,
        'rebates'         => scenario.rebates&.to_f,
        'fees'            => scenario.fees,
        'fni_products'    => customer_fni(scenario.fni_products),
        'line_items'      => customer_line_items(scenario.line_items),
        'apr'             => scenario.apr&.to_f,
        'apr_override'    => scenario.apr_override&.to_f,
        'term_months'     => scenario.term_months,
        'tax_mode'        => scenario.tax_mode,
        'tax_rate'        => scenario.tax_rate&.to_f,
        'unit_price_snapshot' => scenario.unit_price_snapshot&.to_f,
        'amount_financed'     => scenario.amount_financed&.to_f,
        'monthly_payment'     => scenario.monthly_payment&.to_f,
        'out_the_door'        => scenario.out_the_door&.to_f
      }
      begin
        r = scenario.engine_result&.customer_h || {}
        base['total_fees'] = r[:total_fees].to_f
        base['taxes']      = r[:taxes].to_f
        base['trade_equity'] = r[:trade_equity].to_f
        # Prefer engine's computed values so the FE matches the pencil verbatim.
        base['amount_financed'] = r[:amount_financed].to_f if r[:amount_financed]
        base['monthly_payment'] = r[:monthly_payment].to_f if r[:monthly_payment]
        base['out_the_door']    = r[:out_the_door].to_f    if r[:out_the_door]
        base['apr']             = r[:apr].to_f             if r[:apr]
        base['term_months']     = r[:term_months]          if r[:term_months]
      rescue StandardError => e
        Rails.logger.warn "[ShareSnapshotBuilder] engine_result unavailable for scenario #{scenario.id}: #{e.message}"
      end
      base
    end

    def customer_line_items(items)
      Array(items).map do |li|
        li = li.symbolize_keys
        { 'description' => li[:description], 'price' => li[:price].to_f, 'quantity' => (li[:quantity] || 1) }
      end
    end

    def customer_fni(products)
      Array(products).map do |p|
        p = p.symbolize_keys
        { 'name' => p[:name], 'price' => p[:price].to_f }
      end
    end
  end
end
