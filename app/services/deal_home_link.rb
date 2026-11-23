# frozen_string_literal: true

# Keeps a deal pointed at its home in inventory.
#
# A Deal Sheet can start from a home in inventory or from a model in the
# factory catalog. Either way the deal should show its home, so a rep who
# priced the deal on the sheet does not also have to pick the home on the deal.
#
#   - The sheet's own home wins (a home on the lot, the dealer's copy, or the
#     "available to order" home it started from).
#   - A sheet with only a model takes the dealer's "available to order" home
#     for that model when there is exactly one, so the deal shows the model it
#     is waiting on. Winning the deal makes the dealer's own copy of it
#     (DealVehicleStatusSync), the way it always has.
#   - A deal already pointed at a different home of the dealer's own is left
#     alone: someone chose that home.
#
# The serial number or VIN typed on the deal or the sheet (assign_serial!)
# makes the real home: the dealer's copy of an "available to order" home, a
# new home from the model, or the serial on the home already linked.
class DealHomeLink
  class Refused < StandardError; end

  # A different home of the dealer's already carries this serial or VIN.
  class Duplicate < StandardError
    attr_reader :vehicle

    def initialize(vehicle, field)
      @vehicle = vehicle
      super("#{field} #{vehicle.send(field == 'VIN' ? :vin : :serial_number)} is already on #{DealHomeLink.title(vehicle)}")
    end
  end

  def self.title(vehicle)
    [vehicle.year, vehicle.make, vehicle.model].compact.join(' ').presence || "home #{vehicle.id}"
  end

  # The home's real serial: nil for an "available to order" home (the catalog's
  # placeholder) and for a copy still carrying the placeholder it was made with.
  def self.real_serial(vehicle)
    return nil if vehicle.catalog_row?
    return nil if vehicle.cloned_from_id && vehicle.serial_number.to_s.match?(/-C\d+\z/)

    vehicle.serial_number.presence
  end

  def self.real_vin(vehicle)
    return nil if vehicle.catalog_row?
    return nil if vehicle.cloned_from_id && vehicle.vin.to_s.match?(/-C\d+\z/)

    vehicle.vin.presence
  end

  # The dealer's one "available to order" home for this model, nil when there
  # is none or more than one at the deal's location.
  def self.listing_for(company, variant, location_id: nil)
    return nil unless variant

    rows = company.vehicles.active.where(catalog_plan_variant_id: variant.id, status: 'available_to_order').to_a.select(&:catalog_row?)
    if rows.size > 1 && location_id
      here = rows.select { |v| v.location_id.nil? || v.location_id == location_id }
      rows = here if here.any?
    end
    rows.one? ? rows.first : nil
  end

  # Deals waiting on this "available to order" home: pointed at it, or priced on
  # a LIVE sheet built from it. Lost and deleted deals are not waiting.
  def self.deals_waiting_on(vehicle)
    company = vehicle.company
    from_sheets = company.deal_home_builds.where(vehicle_id: vehicle.id, live: true).select(:deal_id)
    company.deals.active.where(vehicle_id: vehicle.id).or(company.deals.active.where(id: from_sheets))
           .where.not(stage: company.lost_stage_keys).order(:created_at)
  end

  # Points the deal (and every record of its that pointed at the old home) at
  # the new one.
  def self.move_deal!(deal, from:, to:)
    deal.update_columns(vehicle_id: to.id, updated_at: Time.current) if deal.vehicle_id.nil? || deal.vehicle_id == from&.id
    deal.association(:vehicle).reset
    # A LIVE sheet priced from the model with no home of its own takes the real
    # one, so it prices the home as it is (on the lot or still coming).
    DealHomeBuild.where(deal_id: deal.id, live: true, vehicle_id: nil, catalog_plan_variant_id: to.catalog_plan_variant_id)
                 .update_all(vehicle_id: to.id) if to.catalog_plan_variant_id
    return unless from

    [DealHomeBuild, DealDeskScenario, Project].each do |model|
      model.where(deal_id: deal.id, vehicle_id: from.id).update_all(vehicle_id: to.id)
    end
  end

  def initialize(deal, build: nil)
    @deal = deal
    @build = build
    @company = deal.company
  end

  # The home the deal should show, from its LIVE sheet:
  #   - the sheet's own home in inventory, always;
  #   - else the model's one "available to order" home, unless the deal already
  #     has a home of the dealer's own (someone picked it on the deal);
  #   - else nothing, and a deal left pointing at another model's
  #     "available to order" home lets go of it.
  def link_from_sheet!
    return nil unless @build&.live?

    current = @deal.vehicle_id && @company.vehicles.find_by(id: @deal.vehicle_id)
    home = @build.vehicle
    if home.nil?
      return nil if current && !current.catalog_row? && !current.is_deleted

      # The sheet itself is not moved onto a model's listing: its price, pack and
      # warnings would change under the rep. Only the deal points at it.
      home = self.class.listing_for(@company, @build.variant, location_id: @deal.location_id)
      if home.nil?
        @deal.update_columns(vehicle_id: nil, updated_at: Time.current) if current&.catalog_row? && current.catalog_plan_variant_id != @build.catalog_plan_variant_id
        return nil
      end
    end
    return nil if current == home

    @deal.update_columns(vehicle_id: home.id, updated_at: Time.current)
    @deal.association(:vehicle).reset
    home
  end

  # The serial number and/or VIN of this deal's home, as it really is.
  #   status:      the home's status after (defaults: unchanged, or On order for a new home)
  #   use_existing_id: link the home that already carries this serial instead
  # Returns the home.
  def assign_serial!(serial_number: nil, vin: nil, status: nil, stock_number: nil, use_existing_id: nil)
    serial_number = serial_number.to_s.strip.presence
    vin = vin.to_s.strip.upcase.presence
    raise Refused, 'Enter the serial number or VIN' unless serial_number || vin
    raise Refused, 'Choose a status' if status.present? && !Vehicle::STATUSES.include?(status)

    current = current_home
    if use_existing_id.present?
      home = @company.vehicles.active.find_by(id: use_existing_id)
      raise Refused, 'That home is not in your inventory' unless home

      Vehicle.transaction do
        home.update!({ serial_number: serial_number || home.serial_number, vin: vin || home.vin }.compact)
        home.update!(status: status) if status.present? && status != home.status && !home.catalog_row?
        attach!(current, home)
      end
      return home
    end

    check_duplicates!(serial_number, vin, current)
    Vehicle.transaction do
      home = if current.nil?
               new_home(serial_number, vin, status.presence || 'on_order', stock_number)
             elsif current.catalog_row?
               copy_of(current, serial_number, vin, status.presence || 'on_order', stock_number)
             else
               attrs = { serial_number: serial_number, vin: vin, stock_number: current.stock_number.presence || stock_number.presence }.compact
               attrs[:status] = status if status.present?
               current.update!(attrs)
               current
             end
      attach!(current, home)
      home
    end
  end

  # A factory PO for this deal that is out with the factory and not received:
  # the serial just typed is the home it was for.
  def receivable_purchase_order
    @deal.purchase_orders.where(kind: 'factory_home', is_deleted: [false, nil])
         .where.not(status: %w[draft received cancelled]).order(:created_at).last
  end

  private

  def current_home
    @build&.vehicle || (@deal.vehicle_id && @company.vehicles.find_by(id: @deal.vehicle_id)) ||
      (@build && self.class.listing_for(@company, @build.variant, location_id: @deal.location_id))
  end

  def check_duplicates!(serial_number, vin, current)
    others = @company.vehicles.active
    others = others.where.not(id: current.id) if current
    if serial_number && (dup = others.where('LOWER(serial_number) = ?', serial_number.downcase).first)
      raise Duplicate.new(dup, 'Serial')
    end
    return unless vin && (dup = others.where('UPPER(vin) = ?', vin).first)

    raise Duplicate.new(dup, 'VIN')
  end

  def copy_of(listing, serial_number, vin, status, stock_number)
    attrs = { stock_number: stock_number.presence, location_id: @deal.location_id || listing.location_id }.compact
    service = VehicleCloneFromCatalogService.new(listing, status: status, attributes: attrs)
    copy = service.call || raise(Refused, "Could not make your copy of this home: #{service.errors.full_messages.to_sentence}")
    # The copy makes up a placeholder serial; the real one replaces it.
    copy.update!({ serial_number: serial_number, vin: vin }.compact)
    copy
  end

  def new_home(serial_number, vin, status, stock_number)
    v = @build&.variant
    raise Refused, 'Choose the home first: pick it on the deal, or start a Deal Sheet' unless v
    raise Refused, 'Enter the serial number from the HUD label' unless serial_number

    @company.vehicles.create!(
      listing_type: 'manufactured_home', condition: 'new', status: status,
      year: Date.current.year, make: v.manufacturer&.name || 'Unknown',
      model: v.manual_home? ? v.catalog_plan&.name.to_s : "#{v.catalog_plan.name} #{v.model_number}".strip,
      serial_number: serial_number, vin: vin, stock_number: stock_number.presence,
      bedrooms: v.beds || 0, bathrooms: v.baths || 0, width: v.width_ft, length: v.length_ft, square_feet: v.square_feet,
      catalog_plan_variant_id: v.manual_home? ? nil : v.id, location_id: @deal.location_id || @build.location_id
    )
  end

  def attach!(from, home)
    self.class.move_deal!(@deal, from: from, to: home)
    @deal.update_columns(vehicle_id: home.id, updated_at: Time.current) if @deal.vehicle_id != home.id
    @deal.association(:vehicle).reset
    @build&.update_columns(vehicle_id: home.id) if @build && @build.vehicle_id != home.id
    # A won deal's home is sold to this buyer.
    DealVehicleStatusSync.mark_sold(@deal, home) if @company.won_stage_keys.include?(@deal.stage.to_s) && home.status != 'sold'
  end
end
