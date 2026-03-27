# frozen_string_literal: true

class Part < ApplicationRecord
  include ActivityTrackable
  include Customizable
  
  # Associations
  belongs_to :company
  belongs_to :category, class_name: 'PartCategory', optional: true
  # Note: manufacturer_name is a text field, no association needed
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true
  
  has_many :supplier_parts, dependent: :destroy
  has_many :suppliers, through: :supplier_parts
  has_many :stock_balances, dependent: :destroy
  has_many :inventory_transactions, dependent: :restrict_with_error
  has_many :reorder_rules, dependent: :destroy
  # NOTE: purchase_order_lines will be added in Phase 2A

  # Configurator associations
  belongs_to :factory, optional: true
  belongs_to :floor_plan, optional: true
  
  # Validations
  validates :company_id, presence: true
  validates :sku, presence: true, length: { maximum: 100 }
  validates :sku, uniqueness: { scope: :company_id, conditions: -> { where(is_deleted: false) } }
  validates :name, presence: true, length: { maximum: 255 }
  validates :uom, presence: true
  validates :inventory_method, inclusion: { in: %w[average_cost fifo lifo] }
  
  # Scopes
  scope :active, -> { where(active: true, is_deleted: false) }
  scope :for_company, ->(company_id) { where(company_id: company_id, is_deleted: false) }
  scope :by_sku, -> { order(:sku) }
  scope :by_name, -> { order(:name) }
  scope :in_category, ->(category_id) { where(category_id: category_id) }
  scope :serialized, -> { where(is_serialized: true) }
  scope :lot_tracked, -> { where(is_lot_tracked: true) }
  scope :configured_homes, -> { where(is_configured_home: true) }
  scope :with_inventory, -> {
    left_joins(:stock_balances)
      .select('parts.*, COALESCE(SUM(stock_balances.on_hand), 0) as total_on_hand')
      .group('parts.id')
  }
  
  # Callbacks
  before_validation :normalize_fields
  before_validation :set_defaults, on: :create
  after_create_commit :fire_parts_added_webhook
  after_update_commit :fire_parts_edited_webhook
  
  # Soft delete
  def soft_delete!
    # Allow deletion if stock is zero; block if stock remains and recent transactions exist
    if total_on_hand > 0
      errors.add(:base, "Cannot delete part with #{total_on_hand} units still in stock. Adjust inventory to 0 first.")
      raise ActiveRecord::RecordInvalid, self
    end
    
    update!(is_deleted: true, deleted_at: Time.current, active: false)
    fire_parts_removed_webhook
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  # Display helpers
  def display_name
    "#{sku} - #{name}"
  end
  
  def full_description
    [name, description].compact.join(' - ')
  end
  
  # Location-based stock lookups (CRITICAL for multi-location)
  def on_hand_at(location_id, bin_id = nil)
    query = stock_balances.where(location_id: location_id)
    query = query.where(bin_id: bin_id) if bin_id.present?
    query.sum(:on_hand)
  end
  
  def available_at(location_id, bin_id = nil)
    query = stock_balances.where(location_id: location_id)
    query = query.where(bin_id: bin_id) if bin_id.present?
    query.sum(:available)
  end
  
  def reserved_at(location_id, bin_id = nil)
    query = stock_balances.where(location_id: location_id)
    query = query.where(bin_id: bin_id) if bin_id.present?
    query.sum(:reserved)
  end
  
  # Company-wide totals
  def total_on_hand
    stock_balances.sum(:on_hand)
  end
  
  def total_available
    stock_balances.sum(:available)
  end
  
  def total_reserved
    stock_balances.sum(:reserved)
  end
  
  # Total value (on_hand * average_cost or default_cost)
  def inventory_value
  cost = average_cost || default_cost || 0
  total_on_hand * cost
  end

  def inventory_value_at(location_id)
  cost = average_cost || default_cost || 0
  on_hand_at(location_id) * cost
  end
  
  # Supplier helpers
  def preferred_supplier
    supplier_parts.find_by(preferred: true)&.supplier
  end
  
  def supplier_count
    supplier_parts.count
  end
  
  # Cost helpers
  def current_cost
    last_cost || average_cost || default_cost || 0
  end
  
  def margin_percent
    return 0 if sale_price.nil? || current_cost.zero?
    ((sale_price - current_cost) / sale_price * 100).round(2)
  end
  
  # Stock status
  def in_stock?
    total_on_hand > 0
  end
  
  def low_stock?(location_id = nil)
    # Check reorder rules for this location
    if location_id.present?
      rule = reorder_rules.find_by(location_id: location_id)
      return false unless rule&.reorder_point.present?
      return available_at(location_id) <= rule.reorder_point
    end
    
    # Company-wide check
    reorder_rules.any? do |rule|
      available_at(rule.location_id) <= rule.reorder_point
    end
  end
  
  def as_json(options = {})
    super(options.merge(
      only: [:id, :sku, :name, :description, :category_id, :uom, :barcode, :manufacturer_part_no, 
             :manufacturer_name, :default_cost, :average_cost, :last_cost, :list_price, :sale_price, 
             :taxable, :active, :created_at, :updated_at,
             :inventory_method, :is_serialized, :is_lot_tracked,
             :weight_lbs, :length_inches, :width_inches, :height_inches, :images],
      methods: [:display_name, :total_on_hand, :total_available, :inventory_value, 
                :preferred_supplier, :margin_percent]
    ))
  end
  
  private
  
  def normalize_fields
    self.sku = sku&.strip&.upcase if sku.present?
    self.name = name&.strip
    self.uom = uom&.strip&.downcase if uom.present?
    self.manufacturer_part_no = manufacturer_part_no&.strip if manufacturer_part_no.present?
  end
  
  def set_defaults
    self.uom ||= 'each'
    self.inventory_method ||= 'average_cost'
    self.taxable = true if taxable.nil?
    self.active = true if active.nil?
    self.is_deleted = false if is_deleted.nil?
  end

  def fire_parts_added_webhook
    WebhookService.fire(
      company_id: company_id,
      event: 'parts.added',
      payload: {
        part_id: id,
        part_sku: sku,
        part_name: name,
        description: description,
        category: category&.name,
        uom: uom,
        manufacturer_name: manufacturer_name,
        default_cost: default_cost,
        sale_price: sale_price,
        is_serialized: is_serialized,
        is_lot_tracked: is_lot_tracked,
        created_at: created_at&.iso8601
      }
    )
  rescue => e
    Rails.logger.error "[Part] Failed to fire parts.added webhook: #{e.message}"
  end

  def fire_parts_edited_webhook
    tracked_fields = %w[
      name sku description category_id uom barcode manufacturer_part_no manufacturer_name
      default_cost average_cost last_cost list_price sale_price taxable active
      inventory_method is_serialized is_lot_tracked
      weight_lbs length_inches width_inches height_inches
    ]

    changed_fields = previous_changes.keys & tracked_fields
    return if changed_fields.empty?

    WebhookService.fire(
      company_id: company_id,
      event: 'parts.edited',
      payload: {
        part_id: id,
        part_sku: sku,
        part_name: name,
        changed_fields: changed_fields,
        changes: changed_fields.each_with_object({}) { |f, h| h[f] = { from: previous_changes[f][0], to: previous_changes[f][1] } },
        total_on_hand: total_on_hand,
        updated_at: updated_at&.iso8601
      }
    )
  rescue => e
    Rails.logger.error "[Part] Failed to fire parts.edited webhook: #{e.message}"
  end

  def fire_parts_removed_webhook
    WebhookService.fire(
      company_id: company_id,
      event: 'parts.removed',
      payload: {
        part_id: id,
        part_sku: sku,
        part_name: name,
        total_on_hand: total_on_hand,
        removed_at: Time.current.iso8601
      }
    )
  rescue => e
    Rails.logger.error "[Part] Failed to fire parts.removed webhook: #{e.message}"
  end

  # ActivityTrackable overrides
  def activity_display_name
    try(:name) || try(:part_number) || "Part ##{id}"
  end

  def activity_module_name
    'inventory'
  end

  def activity_account_id
    nil
  end
end
