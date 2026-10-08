# frozen_string_literal: true

module Truebuild
  # The factory PO for a deal's home (backlog E51), written from its LIVE Deal
  # Sheet: the model and each factory option with its code, quantity and
  # dealer cost. Dealer add-ons, fees, freight and set-up are not the
  # factory's, so they stay off. Allowed at any stage of the deal.
  #
  # The PO keeps a snapshot of those lines, so the sheet can say when it has
  # changed since (a draft PO is rewritten with one click; a sent one needs a
  # change order to the factory, E52).
  #
  # Receiving records the home: its serial number, a home in inventory (an
  # existing one, or a new one made from the model) linked to the deal. It
  # posts nothing; the cost reaches the books with the factory invoice.
  class FactoryOrder
    class Refused < StandardError; end

    def initialize(build)
      @build = build
      @deal = build.deal
    end

    # The PO's item lines: the home and its factory options. A color or finish
    # pick at no charge goes in the colors list instead (colors), where its set
    # names it ("Shutters: Black", not a bare "Black").
    def self.lines(build)
      color_ids = color_option_ids(build)
      build.lines.select { |l| %w[base option].include?(l.kind) && l.priced? }
           .reject { |l| l.kind == 'option' && color_ids.include?(l.catalog_option_id) && l.unit_cost.to_d.zero? }.map do |l|
        { 'kind' => l.kind, 'option_id' => l.catalog_option_id, 'description' => l.kind == 'base' ? home_name(build) : l.label,
          'code' => l.kind == 'base' ? build.variant.model_number : l.factory_code,
          'quantity' => l.quantity.to_d.to_s, 'unit_cost' => l.unit_cost.to_d.round(2).to_s }
      end
    end

    # Every color and finish set offered on this model, with what was picked:
    # the factory needs each one, and an unpicked set is flagged to confirm.
    def self.colors(build)
      sets = offered_sets(build)
      chosen = build.lines.select { |l| l.kind == 'option' && !l.tbd }.index_by(&:catalog_option_id)
      sets.map do |set, options|
        pick = options.find { |o| chosen[o.id] }
        name = pick && (pick.name.to_s.start_with?("#{set}:") ? pick.name.to_s.sub("#{set}:", '').strip : pick.name)
        { 'set' => set, 'choice' => name, 'code' => pick&.factory_code }
      end.sort_by { |c| c['set'].to_s.downcase }
    end

    def self.offered_sets(build)
      variant = build.variant
      book = OptionSource.current_for(variant)
      rows = OptionSource.offered(book, variant, construction: build.construction).select { |op| op.option.status == 'active' }
      rows.map(&:option).uniq.group_by { |o| DealBuild.choice_set(o) }.except(nil)
    end

    def self.color_option_ids(build)
      offered_sets(build).values.flatten.map(&:id).to_set
    end

    def self.home_name(build)
      v = build.variant
      "#{v.manufacturer&.name} #{v.catalog_plan.name} #{v.model_number}".squish
    end

    # Has the sheet's factory part changed since this PO was written?
    def self.changed?(po)
      build = po.deal_home_build || po.deal&.home_build
      return false unless build

      snap = po.sheet_snapshot.to_h
      snap['lines'] != lines(build) || (snap.key?('colors') && snap['colors'] != colors(build)) ||
        po.deal_home_build_id != po.deal&.home_build&.id
    end

    # The supplier record that stands for a manufacturer on POs and bills: the
    # one made for it before, one already named for it, or a new one.
    def self.supplier_for(company, manufacturer)
      code = "MFR-#{manufacturer.id}"
      existing = company.suppliers.where(is_deleted: [false, nil]).find_by(code: code) ||
                 company.suppliers.where(is_deleted: [false, nil]).where('LOWER(name) = ?', manufacturer.name.to_s.downcase).first
      return existing if existing

      cm = company.company_manufacturers.find_by(manufacturer_id: manufacturer.id)
      company.suppliers.create!(name: manufacturer.name, code: code,
                                email: cm&.effective_po_email || manufacturer.po_email.presence || manufacturer.contact_email)
    end

    def create!(supplier:, user:, expected_delivery_date: nil, notes: nil, manufacturer: nil)
      refuse_unless_orderable!
      po = @deal.company.purchase_orders.build(
        kind: 'factory_home', deal: @deal, deal_home_build: @build, supplier: supplier, vendor_id: supplier.id, manufacturer: manufacturer,
        location_id: @deal.location_id || @build.location_id, created_by: user, status: 'draft', order_date: Date.current,
        expected_delivery_date: expected_delivery_date.presence, notes: notes.presence || default_notes, **ship_to
      )
      write_lines(po)
      po.save!
      po
    end

    # Rewrites a draft PO from the sheet as it is now.
    def refresh!(po)
      raise Refused, "#{po.po_number} was already sent; ask the factory for a change instead" unless po.draft?

      refuse_unless_orderable!
      po.lines.each(&:mark_for_destruction)
      po.deal_home_build = @build
      write_lines(po)
      po.save!
      po.lines.reload
      po
    end

    # vehicle: a home already in inventory to link, or nil to add one.
    def self.receive!(po, serial_number:, user:, vehicle: nil, stock_number: nil)
      raise Refused, 'Only a factory PO is received this way' unless po.factory_home?
      raise Refused, "#{po.po_number} is #{po.status}" if %w[received cancelled].include?(po.status)
      # A PO the factory never got cannot have arrived.
      raise Refused, "#{po.po_number} has not been sent: email it or mark it sent first" if po.draft?
      raise Refused, 'Enter the serial number on the home' if serial_number.blank? && vehicle.nil?

      build = po.deal_home_build || po.deal&.home_build
      PurchaseOrder.transaction do
        vehicle ||= add_home(po, build, serial_number, stock_number)
        vehicle.update!(serial_number: serial_number) if serial_number.present? && vehicle.serial_number.blank?
        po.lines.each { |l| l.update!(quantity_received: l.quantity_ordered) }
        po.reload.update!(status: 'received', received_vehicle: vehicle)
        po.update_columns(received_date: Time.current) if po.has_attribute?(:received_date) && po.received_date.nil?
        deal = po.deal
        deal.update_columns(vehicle_id: vehicle.id, updated_at: Time.current) if deal && deal.vehicle_id.nil?
        build&.update_columns(vehicle_id: vehicle.id) if build && build.vehicle_id.nil?
      end
      po
    end

    def self.add_home(po, build, serial_number, stock_number)
      v = build&.variant
      raise Refused, 'Choose the home in inventory: this PO has no model on it' unless v

      po.company.vehicles.create!(
        listing_type: 'manufactured_home', condition: 'new', status: 'reserved',
        year: Date.current.year, make: v.manufacturer&.name || 'Unknown', model: "#{v.catalog_plan.name} #{v.model_number}",
        serial_number: serial_number, stock_number: stock_number.presence,
        bedrooms: v.beds || 0, bathrooms: v.baths || 0, width: v.width_ft, length: v.length_ft, square_feet: v.square_feet,
        catalog_plan_variant_id: v.id, location_id: po.location_id,
        # The factory's cost from the PO, for the inventory record. Nothing is posted.
        dealer_cost: po.subtotal
      )
    end

    private

    def refuse_unless_orderable!
      raise Refused, 'Only the LIVE version of the Deal Sheet is ordered' unless @build.live?
      raise Refused, 'This home is on the lot, so there is nothing to order from the factory' if @build.source == 'lot'
      raise Refused, 'The Deal Sheet has no home yet' unless @build.lines.any? { |l| l.kind == 'base' }
    end

    def write_lines(po)
      lines = self.class.lines(@build)
      lines.each_with_index do |l, i|
        po.lines.build(line_number: i + 1, description: l['description'], manufacturer_part_no: l['code'],
                       catalog_option_id: l['option_id'], quantity_ordered: l['quantity'].to_d, unit_cost: l['unit_cost'].to_d)
      end
      tbd = @build.lines.count(&:tbd)
      po.sheet_snapshot = { 'lines' => lines, 'colors' => self.class.colors(@build), 'version' => @build.version_number,
                            'written_at' => Time.current.iso8601, 'tbd_left_off' => tbd }
    end

    def default_notes
      [@deal.deal_number.present? ? "Deal #{@deal.deal_number}" : nil, "Deal Sheet #{@build.version_name}",
       @build.lines.any?(&:tbd) ? 'TBD options are not on this PO yet.' : nil].compact.join('. ')
    end

    def ship_to
      if @deal.try(:delivery_point) == 'lot' || @deal.delivery_street.blank?
        loc = @deal.location
        return {} unless loc

        { ship_to_name: loc.name, ship_to_address1: loc.try(:address_line1) || loc.try(:address), ship_to_city: loc.try(:city),
          ship_to_state: loc.try(:state), ship_to_zip: loc.try(:zip) }.compact
      else
        { ship_to_name: @deal.customer_display_name, ship_to_address1: @deal.delivery_street, ship_to_city: @deal.delivery_city,
          ship_to_state: @deal.delivery_state, ship_to_zip: @deal.delivery_zip }.compact
      end
    end
  end
end
