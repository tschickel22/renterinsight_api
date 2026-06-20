# frozen_string_literal: true

# Clones a Champion IMS catalog row (source='champion_ims') into a dealer-owned
# working copy (source='champion_ims_clone'). Triggered when a dealer attempts
# to change the status of a catalog row to anything other than 'available_to_order'.
#
# The catalog row stays untouched and continues to receive sync updates. The
# clone is fully dealer-owned: sync never writes to it, and the dealer can edit
# any field freely.
#
# Inventory ID format for clones uses suffix-style for visual distinction:
#   Catalog row:  MH-20260415-ABC789
#   First clone:  MH-20260415-ABC789-C1
#   Second clone: MH-20260415-ABC789-C2
#
# Usage:
#   service = VehicleCloneFromCatalogService.new(
#     catalog_vehicle,
#     status: 'reserved',
#     attributes: { serial_number: 'CHAMP-12345', vin: 'XYZ', location_id: 78 }
#   )
#   clone = service.call  # returns the newly-created clone Vehicle, or nil on failure
#   service.errors        # ActiveModel-style errors if save failed
#
# Note: not under `Vehicles::` namespace because the MCP filesystem cannot create
# the `app/services/vehicles/` subdirectory. Move into namespace later if desired.
class VehicleCloneFromCatalogService
  # Fields that should NOT be copied from the catalog row to the clone.
  # Everything else is copied verbatim.
  NON_COPYABLE_FIELDS = %w[
    id
    inventory_id
    created_at
    updated_at
    cloned_from_id
    source
    status
    champion_last_seen_at
    serial_number
    vin
    catalog_source_id
    catalog_source_key
    catalog_content_hash
    catalog_last_seen_at
  ].freeze

  attr_reader :catalog_vehicle, :requested_status, :attribute_overrides, :errors

  def initialize(catalog_vehicle, status:, attributes: {})
    @catalog_vehicle      = catalog_vehicle
    @requested_status     = status.to_s
    @attribute_overrides  = (attributes || {}).symbolize_keys
    @errors               = ActiveModel::Errors.new(self)
  end

  # Returns the newly-created clone Vehicle on success, nil on failure.
  # Inspect `service.errors` after call to see what went wrong.
  def call
    unless catalog_vehicle.is_a?(Vehicle) && catalog_vehicle.cloneable?
      errors.add(:base, 'Source vehicle is not a catalog row')
      return nil
    end

    if requested_status.blank? || requested_status == 'available_to_order'
      errors.add(:status, 'must be a non-catalog status (reserved, sold, pending, available, service)')
      return nil
    end

    unless Vehicle::STATUSES.include?(requested_status)
      errors.add(:status, "is not a valid status: #{requested_status}")
      return nil
    end

    clone = build_clone

    if clone.save
      Rails.logger.info(
        "[CloneFromCatalog] Created clone vehicle ##{clone.id} (#{clone.inventory_id}) " \
        "from catalog ##{catalog_vehicle.id} (#{catalog_vehicle.inventory_id}) " \
        "with status=#{clone.status}"
      )
      clone
    else
      clone.errors.full_messages.each { |msg| errors.add(:base, msg) }
      Rails.logger.warn(
        "[CloneFromCatalog] Failed to clone catalog ##{catalog_vehicle.id}: " \
        "#{clone.errors.full_messages.join(', ')}"
      )
      nil
    end
  end

  private

  def build_clone
    copyable_attrs = catalog_vehicle.attributes.except(*NON_COPYABLE_FIELDS)

    clone = catalog_vehicle.company.vehicles.build(copyable_attrs)
    # Clone source mirrors the catalog kind (champion_ims_clone / catalog_import_clone).
    clone.source           = catalog_vehicle.clone_source
    clone.cloned_from_id   = catalog_vehicle.id
    clone.status           = requested_status
    clone.is_deleted       = false
    clone.inventory_id     = generate_clone_inventory_id

    # Generate placeholder serial_number / vin per-clone. Catalog rows use a
    # synthetic value ("CHAMP-{champion_model_id}") which would collide on
    # clone insert because Vehicle has a uniqueness validation per company
    # for both columns. Suffix with the same -C{n} as inventory_id so the
    # dealer can immediately tell which clone this is until they enter the
    # real values upon receiving the home.
    suffix = clone.inventory_id.to_s[/-C\d+\z/].to_s # "-C1" style
    if catalog_vehicle.is_manufactured_home?
      base_serial = catalog_vehicle.serial_number.to_s.sub(/-C\d+\z/, '')
      clone.serial_number = "#{base_serial}#{suffix}"
    end
    if catalog_vehicle.is_rv? && catalog_vehicle.vin.present?
      base_vin = catalog_vehicle.vin.to_s.sub(/-C\d+\z/, '')
      clone.vin = "#{base_vin}#{suffix}"
    end

    # Apply dealer-provided overrides AFTER copy + defaults
    attribute_overrides.each do |key, value|
      clone.public_send("#{key}=", value) if clone.respond_to?("#{key}=")
    end

    # Default location to catalog's location if not overridden, but allow nil
    # explicitly (apply_to_all_locations catalog rows have nil location)
    if !attribute_overrides.key?(:location_id) && clone.location_id.nil?
      clone.location_id = catalog_vehicle.location_id
    end

    clone
  end

  # Suffix-style inventory ID: parent's ID + "-C#{n}" where n is the next
  # available clone number. If parent is "MH-20260415-ABC789" and there are
  # already 2 clones, this returns "MH-20260415-ABC789-C3".
  def generate_clone_inventory_id
    base       = catalog_vehicle.inventory_id.to_s.sub(/-C\d+\z/, '')
    next_index = catalog_vehicle.clones.count + 1
    candidate  = "#{base}-C#{next_index}"

    # Defensive: if somehow the candidate exists (race / restored deleted clone),
    # bump until we find an available slot
    while catalog_vehicle.company.vehicles.where(inventory_id: candidate).exists?
      next_index += 1
      candidate = "#{base}-C#{next_index}"
    end

    candidate
  end
end
