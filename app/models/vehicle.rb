# frozen_string_literal: true

class Vehicle < ApplicationRecord
  include ActivityTrackable
  include LocationAware
  include WebhookNotifiable
  include Reportable

  def self.reportable_config
    {
      label: "Homes",
      category: "inventory",
      fields: [
        { key: "id",           label: "ID",           type: "number", filterable: true,  sortable: true  },
        { key: "inventory_id", label: "Inventory ID", type: "string", filterable: true,  sortable: true  },
        { key: "listing_type", label: "Type",         type: "enum",   filterable: true,  sortable: true  },
        { key: "status",       label: "Status",       type: "enum",   filterable: true,  sortable: true  },
        { key: "condition",    label: "Condition",    type: "enum",   filterable: true,  sortable: true  },
        { key: "year",         label: "Year",         type: "number", filterable: true,  sortable: true  },
        { key: "make",         label: "Make",         type: "string", filterable: true,  sortable: true  },
        { key: "model",        label: "Model",        type: "string", filterable: true,  sortable: true  },
        { key: "trim",         label: "Trim",         type: "string", filterable: true,  sortable: false },
        { key: "serial_number",label: "Serial Number",type: "string", filterable: true,  sortable: true  },
        { key: "vin",          label: "VIN",          type: "string", filterable: true,  sortable: true  },
        { key: "stock_number", label: "Stock Number", type: "string", filterable: true,  sortable: true  },
        { key: "bedrooms",     label: "Bedrooms",     type: "number", filterable: true,  sortable: true  },
        { key: "bathrooms",    label: "Bathrooms",    type: "number", filterable: true,  sortable: true  },
        { key: "msrp",         label: "Base Sale Price", type: "number", filterable: true,  sortable: true  },
        { key: "sale_price",   label: "Special Sale Price", type: "number", filterable: true,  sortable: true  },
        { key: "cost",         label: "Cost",         type: "number", filterable: true,  sortable: true  },
        { key: "color",        label: "Color",        type: "string", filterable: true,  sortable: false },
        { key: "created_at",   label: "Created At",   type: "date",   filterable: true,  sortable: true  },
        { key: "updated_at",   label: "Updated At",   type: "date",   filterable: true,  sortable: true  }
      ]
    }
  end
  
  # Virtual attribute for import: accepts URL string, converts to floor_plan_images array
  attr_accessor :floor_plan_url

  # Associations
  belongs_to :company, optional: true
  belongs_to :location, optional: true
  belongs_to :floor_plan, optional: true
  has_many :deals, dependent: :nullify
  has_many :quotes, dependent: :nullify
  has_many :deal_desk_scenarios, dependent: :nullify
  has_many :listings, dependent: :destroy
  has_many :note_records, as: :entity, class_name: 'Note', dependent: :destroy
  has_many :inventory_packages, dependent: :destroy
  has_many :tracked_links, dependent: :nullify
  has_many :documents, class_name: 'VehicleDocument', dependent: :destroy
  # Internal-only manufacturer-invoice capture (Max Advance Phase 1). One per vehicle.
  has_one :invoice, class_name: 'VehicleInvoice', dependent: :destroy

  # Tags (polymorphic association)
  has_many :tag_assignments, as: :entity, dependent: :destroy
  has_many :tags, through: :tag_assignments

  # Inventory features (Option B - individual searchable/filterable records)
  has_many :inventory_features, dependent: :destroy

  # Champion IMS catalog/clone lineage:
  #   - `catalog_source` is the catalog Vehicle this row was cloned from
  #     (only set on `source: 'champion_ims_clone'` rows)
  #   - `clones` are working copies the dealer created when changing the
  #     status of this catalog row (only populated on `source: 'champion_ims'` rows)
  belongs_to :catalog_source, class_name: 'Vehicle', foreign_key: 'cloned_from_id', optional: true
  has_many   :clones,         class_name: 'Vehicle', foreign_key: 'cloned_from_id', dependent: :nullify

  # Vehicle types
  TYPES = %w[rv manufactured_home].freeze
  STATUSES = %w[available reserved sold pending service available_to_order].freeze
  CONDITIONS = %w[new used].freeze

  # Champion IMS source values:
  #   - 'manual'              — default, dealer-created
  #   - 'champion_ims'        — catalog row from IMS feed (immutable to dealers; sync writes only)
  #   - 'champion_ims_clone'  — dealer-owned working copy of a catalog row, created via
  #                              status-change interception. Sync NEVER touches these.
  CHAMPION_SOURCES = %w[manual champion_ims champion_ims_clone].freeze

  # Legacy whitelist — retained for backwards-compat in case anything else references it,
  # but the cloning architecture means dealers never edit catalog rows directly.
  # Sync now does a full upsert on catalog rows.
  CHAMPION_MANAGED_FIELDS = %w[
    make model year bedrooms bathrooms square_feet home_type features
    champion_images champion_raw_payload champion_last_seen_at
  ].freeze
  
  # RV Classes for RVT.com syndication
  RV_CLASSES = [
    'Class A',
    'Class B',
    'Class C',
    'Travel Trailer',
    'Fifth Wheel',
    'Toy Hauler',
    'Pop-Up Camper',
    'Truck Camper',
    'Park Model',
    'Motorhome',
    'Camper Van',
    'Teardrop Trailer',
    'Hybrid Trailer'
  ].freeze
  
  # Fuel types
  FUEL_TYPES = %w[Gas Diesel Electric Hybrid Propane].freeze
  
  # Engine types
  ENGINE_TYPES = ['V6', 'V8', 'V10', 'I4', 'I6', 'Diesel', 'Other'].freeze

  # Validations
  validates :inventory_id, presence: true, uniqueness: { scope: :company_id, conditions: -> { where(is_deleted: [false, nil]) } }
  validates :listing_type, presence: true, inclusion: { in: TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :year, :make, :model, presence: true
  validates :year, numericality: { only_integer: true, greater_than: 1900, less_than_or_equal_to: -> { Date.current.year + 1 } }

  # RV-specific validations
  with_options if: -> { listing_type == 'rv' } do
    validates :vin, presence: true, uniqueness: { scope: :company_id }
  end

  # MH-specific validations
  # FIX: Removed strict numericality validation to allow "4+" values
  with_options if: -> { listing_type == 'manufactured_home' } do
    validates :serial_number, presence: true, uniqueness: { scope: :company_id, conditions: -> { where(is_deleted: [false, nil]) } }
    validates :bedrooms, :bathrooms, presence: true
    # Bedrooms and bathrooms are validated in normalize_bedroom_bathroom_values callback
  end

  # Scopes
  scope :active, -> { where(is_deleted: false) }
  scope :available, -> { active.where(status: 'available') }
  scope :reserved, -> { active.where(status: 'reserved') }
  scope :sold, -> { active.where(status: 'sold') }
  scope :pending, -> { active.where(status: 'pending') }
  scope :available_to_order, -> { active.where(status: 'available_to_order') }
  scope :in_inventory, -> { active.where.not(status: 'available_to_order') }  # Exclude catalog items from inventory counts
  scope :by_type, ->(type) { where(listing_type: type) }
  scope :by_status, ->(status) {
    # Support comma-separated status values (e.g., 'available,available_to_order')
    statuses = status.is_a?(Array) ? status : status.to_s.split(',').map(&:strip)
    where(status: statuses)
  }
  scope :by_year, ->(year) { where(year: year) }
  scope :by_make, ->(make) { where('LOWER(make) = ?', make.to_s.downcase) }
  scope :by_model, ->(model) { where('LOWER(model) = ?', model.to_s.downcase) }
  scope :rvs, -> { where(listing_type: 'rv') }
  scope :manufactured_homes, -> { where(listing_type: 'manufactured_home') }
  scope :search, ->(query) do
    # Use case-insensitive search that works with both SQLite and PostgreSQL
    operator = connection.adapter_name.downcase.include?('sqlite') ? 'LIKE' : 'ILIKE'
    where(
      "inventory_id #{operator} ? OR vin #{operator} ? OR serial_number #{operator} ? OR make #{operator} ? OR model #{operator} ? OR description #{operator} ?",
      "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%"
    )
  end
  scope :recent, -> { order(created_at: :desc) }

  # Champion IMS sync scopes
  scope :champion_sourced, -> { where(source: 'champion_ims') }
  scope :champion_catalog,  -> { where(source: 'champion_ims') }                       # alias — catalog rows
  scope :champion_clones,   -> { where(source: 'champion_ims_clone') }                  # dealer working copies
  scope :champion_any,      -> { where(source: %w[champion_ims champion_ims_clone]) }   # both
  scope :needs_pricing_from_champion, -> { champion_sourced.where(sale_price: nil) }

  # Source filter scopes for the inventory list / brochure / feed `source_filter` param.
  # `dealer_preferred`: hide a catalog row IF the dealer has any non-deleted clone of it
  #   for this scope (the clone supersedes the original). Used by feeds and brochures so
  #   customers see exactly one version of each home.
  # `originals_only`:    catalog rows + manual entries; excludes clones (no dupes from edits)
  # `dealer_only`:       clones + manual entries; excludes raw catalog rows
  # `synced_only`:       just catalog rows (debugging / sync verification)
  scope :originals_only, -> { where("source IS NULL OR source IN (?)", %w[manual champion_ims]) }
  scope :dealer_only,    -> { where("source IS NULL OR source IN (?)", %w[manual champion_ims_clone]) }
  scope :synced_only,    -> { where(source: 'champion_ims') }
  scope :dealer_preferred, -> {
    # Subquery: catalog row IDs that have at least one non-deleted clone in scope.
    # We hide those catalog rows because the clone is the dealer-preferred version.
    superseded_catalog_ids = where(source: 'champion_ims_clone', is_deleted: [false, nil])
                              .where.not(cloned_from_id: nil)
                              .select(:cloned_from_id)
    where.not(id: superseded_catalog_ids)
  }

  # Callbacks
  before_validation :normalize_fields
  before_validation :normalize_bedroom_bathroom_values  # FIX: Added to handle "4+" values
  before_validation :generate_inventory_id, on: :create
  after_commit :fire_lifecycle_webhooks, if: :saved_change_to_status?
  after_save :sync_inventory_features, if: :saved_change_to_features?
  before_save :process_media_urls

  # Soft delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current)
  end

  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end

  # Auto-compute discounted sale price when discount fields change
  before_save :compute_discounted_price

  # Structured "landed" cost of the unit — the single source of truth for cost.
  # `total_cost` is authoritative when maintained; otherwise the sum of its components
  # (dealer_cost + freight_cost + pdi_cost). It is NOT maintained by any callback, so we
  # compute it on read. Returns nil when no cost has been entered — 0 is treated as
  # MISSING, never as free. Callers must flag nil as "cost not entered" rather than
  # assuming a default margin.
  def structured_cost
    tc = total_cost.to_f
    return tc.round(2) if tc > 0

    components_sum = [dealer_cost, freight_cost, pdi_cost].compact.sum(&:to_f)
    components_sum > 0 ? components_sum.round(2) : nil
  end

  # Floor-plan interest accrued to date. Floor-plan rates are quoted ANNUALLY (APR), so
  # the monthly accrual is amount * (annual_rate% / 12) per month. Counts whole months
  # from floor_plan_start_date to today (or floor_plan_curtailed_at if curtailed). Returns
  # 0.0 when floor-plan tracking isn't set up, so a deal can safely auto-populate an
  # estimate the accountant can override.
  def floor_plan_interest_to_date(as_of: Date.current)
    return 0.0 if floor_plan_amount.to_f <= 0 || floor_plan_rate.to_f <= 0 || floor_plan_start_date.blank?

    end_date = (floor_plan_curtailed_at || as_of).to_date
    start = floor_plan_start_date.to_date
    months = (end_date.year * 12 + end_date.month) - (start.year * 12 + start.month)
    months = 0 if months.negative?

    monthly_rate = floor_plan_rate.to_f / 100.0 / 12.0
    (floor_plan_amount.to_f * monthly_rate * months).round(2)
  end

  # Display helpers
  def display_name
    "#{year} #{make} #{model}#{trim.present? ? " #{trim}" : ''}"
  end

  def identifier
    listing_type == 'rv' ? vin : serial_number
  end

  def full_location
    return nil unless location_city && location_state
    [location_city, location_state].compact.join(', ')
  end

  def location_address
    parts = [address1, address2].compact.reject(&:blank?)
    parts.any? ? parts.join(', ') : ''
  end

  def price_display
    sale_price || rent_price
  end

  # Computed total: sale_price + all packages that are included_in_total
  def total_home_price
    package_total = inventory_packages.included_in_total.sum(:price).to_f

    if respond_to?(:special_discount_enabled) && special_discount_enabled && discounted_price.present?
      # When discount includes packages in its calculation, don't add them again
      case discount_type
      when '$ Flat Amount', '% of Total w/ Packages'
        discounted_price.to_f
      else
        # '% of Home Price' discounts base MSRP only — add packages on top
        discounted_price.to_f + package_total
      end
    else
      # No discount: use MSRP as base, fall back to sale_price, add packages
      base = msrp.to_f > 0 ? msrp.to_f : sale_price.to_f
      base + package_total
    end
  end

  def is_rv?
    listing_type == 'rv'
  end

  def is_manufactured_home?
    listing_type == 'manufactured_home'
  end

  # True when this vehicle was imported from the Champion IMS feed (catalog row).
  def champion_sourced?
    source == 'champion_ims'
  end
  alias_method :catalog?, :champion_sourced?

  # True when this vehicle is a dealer-owned clone of a Champion catalog row.
  def champion_clone?
    source == 'champion_ims_clone'
  end
  alias_method :clone?, :champion_clone?

  # True if any version of this row should NOT be cloned again on edit.
  # Clones-of-clones are not allowed: editing a clone updates it in place.
  def cloneable?
    catalog?
  end

  # True when status change should trigger a clone instead of an in-place update.
  # Catalog rows must stay at `available_to_order`; any other status means the
  # dealer is taking action on a specific home and needs their own working copy.
  def requires_clone_on_status_change?(new_status)
    catalog? && new_status.to_s != 'available_to_order'
  end

  # True when this catalog row has any associated dealer activity that should
  # prevent it from being tombstoned even if Champion drops it from the feed.
  def has_dealer_activity?
    return false unless catalog?
    clones.any? || deals.any? || quotes.any? || listings.any? || inventory_packages.any?
  end
  
  # RV-specific helper methods
  def total_water_capacity
    return nil unless is_rv?
    (fresh_water_capacity.to_f + gray_water_capacity.to_f + black_water_capacity.to_f).round(2)
  end
  
  def has_slideouts?
    slideouts.to_i > 0
  end
  
  def has_generator?
    generator == true
  end
  
  def rvt_ready?
    return false unless is_rv?
    # RVT.com requires: rv_class, year, make, model, price
    rv_class.present? && year.present? && make.present? && model.present? && (sale_price.present? || rent_price.present?)
  end

  private

  def normalize_fields
    # Champion catalog rows come pre-formatted from the manufacturer's master
    # data — titleizing them breaks part numbers (DAP1676H32222 → "Dap 1676 H 32222")
    # and re-spaces model names ("Skyliner 6380P" → "Skyliner 6380 P"), causing
    # an infinite update loop on every sync.
    if source != 'champion_ims'
      self.make = make&.titleize
      self.model = model&.titleize
    end
    self.status = normalize_status(status)
    self.listing_type = listing_type&.downcase

    # MH: Auto-copy vin to serial_number if serial_number is blank
    if listing_type == 'manufactured_home' && serial_number.blank? && vin.present?
      self.serial_number = vin
    end
  end

  # FIX: New method to handle "4+" bedroom/bathroom values
  # Process photo_url (pipe-delimited → images array) and floor_plan_url → floor_plan_images
  def process_media_urls
    # Split pipe-delimited photo_url into images array
    if photo_url.present? && photo_url.include?('|')
      urls = photo_url.split('|').map(&:strip).reject(&:blank?)
      self.photo_url = urls.first
      self.images = urls.map { |url| { 'url' => url } } if images.blank? || images.empty?
    end

    # Convert floor_plan_url string → floor_plan_images array
    if floor_plan_url.present? && (floor_plan_images.blank? || floor_plan_images.empty?)
      fp_urls = floor_plan_url.to_s.split('|').map(&:strip).reject(&:blank?)
      self.floor_plan_images = fp_urls.map { |url| { 'url' => url } }
    end

    # If no photos but floor plans exist, copy first floor plan as primary photo
    if photo_url.blank? && floor_plan_images.present? && floor_plan_images.any?
      first_fp = floor_plan_images.first
      fp_url = first_fp.is_a?(Hash) ? (first_fp['url'] || first_fp[:url]) : first_fp
      self.photo_url = fp_url if fp_url.present?
      self.images = [{ 'url' => fp_url }] if (images.blank? || images.empty?) && fp_url.present?
    end
  end

  def normalize_status(raw)
    return 'available' if raw.blank?
    mapped = {
      'active' => 'available',
      'in stock' => 'available',
      'for sale' => 'available',
      'on hold' => 'reserved',
      'under contract' => 'pending',
      'available to order' => 'available_to_order',
      'availabletoorder' => 'available_to_order',
      'to order' => 'available_to_order',
      'catalog' => 'available_to_order',
      'on order' => 'available_to_order',
    }
    downcased = raw.to_s.strip.downcase
    mapped[downcased] || (STATUSES.include?(downcased) ? downcased : 'available')
  end

  def normalize_bedroom_bathroom_values
    return unless listing_type == 'manufactured_home'
    
    # Convert "4+" to 4 for storage
    # This allows the form to submit "4+" but stores it as a valid number
    if bedrooms.present?
      bedroom_str = bedrooms.to_s.strip
      if bedroom_str =~ /^(\d+)\+?$/
        self.bedrooms = $1.to_i
      end
    end
    
    if bathrooms.present?
      bathroom_str = bathrooms.to_s.strip
      if bathroom_str =~ /^(\d+(?:\.\d+)?)\+?$/
        self.bathrooms = $1.to_f
      end
    end
  end

  def generate_inventory_id
    return if inventory_id.present?
    
    prefix = listing_type == 'rv' ? 'RV' : 'MH'
    timestamp = Time.current.strftime('%Y%m%d')
    random = SecureRandom.hex(3).upcase
    
    self.inventory_id = "#{prefix}-#{timestamp}-#{random}"
  end

  # Compute discounted price and auto-write to sale_price for marketing views
  def compute_discounted_price
    return unless respond_to?(:special_discount_enabled)

    # If discount is disabled, clear the computed prices
    unless special_discount_enabled
      self.discounted_price = nil
      self.sale_price = nil if special_discount_enabled_changed?
      return
    end

    return if discount_type.blank? || discount_value.blank? || discount_value.to_f <= 0

    base = msrp.to_f
    return if base <= 0

    # Calculate total home price (base + included packages)
    package_total = inventory_packages.where(include_in_total: true).sum(:price).to_f
    total_with_packages = base + package_total

    computed = case discount_type
              when '% of Home Price'
                base - (base * (discount_value.to_f / 100.0))
              when '$ Flat Amount'
                total_with_packages - discount_value.to_f
              when '% of Total w/ Packages'
                total_with_packages - (total_with_packages * (discount_value.to_f / 100.0))
              else
                nil
              end

    if computed && computed > 0
      self.discounted_price = computed.round(2)
      self.sale_price = computed.round(2)  # Feeds marketing/public views
    end
  end

  # Fire custom lifecycle webhook events on status transitions
  # WebhookNotifiable handles generic vehicle.created/updated/deleted
  # This adds vehicle.sold and vehicle.archived for specific transitions.
  # Sync the features JSON array → inventory_features table (Option B)
  # Runs whenever the features column changes, keeping both in sync.
  def sync_inventory_features
    return unless company_id.present?
    return unless features.is_a?(Array)

    existing_names = inventory_features.pluck(:name).map(&:downcase)
    new_names = features.map(&:strip).reject(&:blank?)

    # Add new features not yet in the table
    new_names.each do |name|
      next if existing_names.include?(name.downcase)
      inventory_features.create(name: name, company_id: company_id, is_standard: true)
    rescue ActiveRecord::RecordInvalid
      # Skip duplicates
    end

    # Remove standard features no longer in the array (keep custom ones)
    if new_names.any?
      stale = inventory_features.standard.where.not('LOWER(name) IN (?)', new_names.map(&:downcase))
      stale.destroy_all
    end
  end

  def fire_lifecycle_webhooks
    event = case status
            when 'sold' then 'vehicle.sold'
            end

    return unless event

    WebhookService.fire(
      company_id: company_id,
      event: event,
      payload: webhook_payload
    )
  rescue => e
    Rails.logger.error "[Vehicle] Failed to fire lifecycle webhook #{event}: #{e.message}"
  end

  # ActivityTrackable overrides
  def activity_display_name
    [try(:year), try(:make), try(:model)].compact.join(' ').presence || "Vehicle ##{id}"
  end

  def activity_module_name
    'inventory'
  end

  def activity_account_id
    nil
  end
end
