# frozen_string_literal: true

class Quote < ApplicationRecord
  include Addressable
  include Buyable
  include Communicable
  include LocationAware
  include WebhookNotifiable
  # Quote Statuses
  STATUSES = %w[draft sent viewed accepted rejected expired].freeze
  
  # Item categories (mirrors invoice_items)
  ITEM_CATEGORIES = %w[home land accessory product service fee package basement other].freeze

  # Categories that default to taxable
  TAXABLE_CATEGORIES = %w[home land package accessory product].freeze

  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  belongs_to :vehicle, optional: true
  belongs_to :deal, optional: true
  belongs_to :sales_rep, class_name: 'User', optional: true
  has_many :note_records, as: :entity, class_name: 'Note', dependent: :destroy
  has_many :quote_inventory_usages, dependent: :destroy
  
  # Tags (polymorphic association)
  has_many :tag_assignments, as: :entity, dependent: :destroy
  has_many :tags, through: :tag_assignments
  
  # Validations
  validates :quote_number, presence: true, uniqueness: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :subtotal, :tax, :total, numericality: { greater_than_or_equal_to: 0 }
  validate :items_must_be_array
  validate :valid_until_must_be_future, if: -> { valid_until.present? && new_record? }
  
  # Scopes
  scope :active, -> { where(is_deleted: false) }
  scope :by_status, ->(status) { where(status: status) }
  scope :by_account, ->(account_id) { where(account_id: account_id) }
  scope :by_contact, ->(contact_id) { where(contact_id: contact_id) }
  scope :by_customer, ->(customer_id) { where(customer_id: customer_id) }
  scope :by_vehicle, ->(vehicle_id) { where(vehicle_id: vehicle_id) }
  scope :valid, -> { where('valid_until IS NULL OR valid_until >= ?', Date.current) }
  scope :expired, -> { where('valid_until < ?', Date.current) }
  scope :by_deal, ->(deal_id) { where(deal_id: deal_id) }
  scope :search, ->(query) do
    where('quote_number ILIKE ? OR notes ILIKE ? OR terms ILIKE ?', "%#{query}%", "%#{query}%", "%#{query}%")
  end
  scope :recent, -> { order(created_at: :desc) }
  
  # Callbacks
  before_validation :generate_quote_number, on: :create
  before_validation :generate_public_token, on: :create
  before_validation :calculate_totals
  before_validation :check_expiration
  after_commit :fire_lifecycle_webhooks, if: :saved_change_to_status?
  
  # Soft Delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current)
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  # Public link for email viewing (no login required)
  def public_link
    # Ensure public_token exists (for existing quotes created before token was added)
    generate_public_token if public_token.blank?
    save! if changed?
    
    "#{ENV['FRONTEND_URL'] || 'https://staging.crm.landlordinsight.com'}/q/#{public_token}"
  end
  
  # Status transitions
  def send!
    # Allow sending for draft quotes or resending for sent/viewed quotes
    return false unless may_send?
    
    is_resend = !draft? && sent_at.present?
    
    update!(
      status: 'sent',
      sent_at: is_resend ? sent_at : Time.current,  # Keep original sent_at
      last_sent_at: Time.current,  # Always update last_sent_at
      resend_count: is_resend ? (resend_count + 1) : 0  # Increment on resend
    )
  end
  
  def may_send?
    %w[draft sent viewed].include?(status)
  end
  
  def mark_viewed!
    return false unless sent?
    
    update!(
      status: 'viewed',
      viewed_at: Time.current
    )
  end
  
  def accept!
    return false unless %w[sent viewed].include?(status)
    
    update!(
      status: 'accepted',
      accepted_at: Time.current
    )
  end
  
  def reject!
    return false unless %w[sent viewed].include?(status)
    
    update!(
      status: 'rejected',
      rejected_at: Time.current
    )
  end
  
  def expire!
    update!(status: 'expired')
  end
  
  # Status checks
  def draft?
    status == 'draft'
  end
  
  def sent?
    status == 'sent'
  end
  
  def viewed?
    status == 'viewed'
  end
  
  def accepted?
    status == 'accepted'
  end
  
  def rejected?
    status == 'rejected'
  end
  
  def expired?
    status == 'expired' || (valid_until.present? && valid_until < Date.current)
  end
  
  def editable?
    draft? || sent?
  end
  
  # Vehicle display helper
  def vehicle_display_name
    vehicle&.display_name
  end
  
  # JSON serialization
  def as_json(options = {})
    # Build JSON manually to avoid JSONB serialization issues
    json = {
      'id' => id.to_s,
      'quote_number' => quote_number,
      'accountId' => account_id&.to_s,
      'contactId' => contact_id&.to_s,
      'customerId' => customer_id,
      'vehicleId' => vehicle_id&.to_s,
      'dealId' => deal_id&.to_s,
      'salesRepId' => sales_rep_id&.to_s,
      'status' => status,
      'subtotal' => subtotal,
      'tax' => tax,
      'taxRate' => tax_rate,
      'total' => total,
      'notes' => notes,
      'terms' => terms,
      'pricingDisplay' => pricing_display || 'detailed',
      'drawSchedule' => draw_schedule,
      'sent_at' => sent_at,
      'last_sent_at' => last_sent_at,
      'resend_count' => resend_count || 0,
      'viewed_at' => viewed_at,
      'accepted_at' => accepted_at,
      'rejected_at' => rejected_at,
      
      # Handle items - convert keys from snake_case to camelCase for frontend
      'items' => serialize_items(items),
      'lineItems' => serialize_items(items),
      
      # Add account, contact, vehicle, and deal names
      'accountName' => account&.name,
      'contactName' => contact ? "#{contact.first_name} #{contact.last_name}".strip : nil,
      'vehicleName' => vehicle&.display_name,
      'dealName' => deal&.name,
      'salesRepName' => sales_rep ? "#{sales_rep.first_name} #{sales_rep.last_name}".strip : nil,
      
      # Format dates
      'validUntil' => valid_until,
      'createdAt' => created_at,
      'updatedAt' => updated_at
    }
    
    # Add custom_fields to top level for easier frontend access
    if custom_fields.is_a?(Hash)
      custom_fields.each do |key, value|
        # Convert snake_case keys to camelCase for frontend
        camel_key = key.to_s.camelize(:lower)
        json[camel_key] = value
      end
    end
    
    # Include related data if requested
    if options[:include_account] && account
      json['account'] = {
        id: account.id.to_s,
        name: account.name,
        email: account.email,
        phone: account.phone
      }
    end
    
    if options[:include_contact] && contact
      json['contact'] = {
        id: contact.id.to_s,
        firstName: contact.first_name,
        lastName: contact.last_name,
        email: contact.email,
        phone: contact.phone
      }
    end
    
    if options[:include_vehicle] && vehicle
      json['vehicle'] = {
        id: vehicle.id.to_s,
        inventoryId: vehicle.inventory_id,
        displayName: vehicle.display_name,
        type: vehicle.listing_type,
        year: vehicle.year,
        make: vehicle.make,
        model: vehicle.model
      }
    end

    if options[:include_deal] && deal
      json['deal'] = {
        id: deal.id.to_s,
        name: deal.name,
        value: deal.value,
        stage: deal.stage
      }
    end
    
    # Include inventory usage if requested
    if options[:include_inventory]
      json['inventoryUsages'] = quote_inventory_usages.map do |usage|
        {
          id: usage.id,
          partId: usage.part_id,
          partNumber: usage.part&.part_number,
          partName: usage.part&.name,
          quantity: usage.quantity,
          unitCost: usage.unit_cost,
          unitPrice: usage.unit_price,
          itemIndex: usage.item_index,
          used: usage.used,
          usedAt: usage.used_at,
          usedByName: usage.used_by&.name,
          stockLevel: usage.stock_level,
          stockAvailable: usage.stock_available?,
          locationName: usage.location&.name
        }
      end
    end
    
    json
  end
  
  # Required by Communicable concern
  def primary_email
    contact&.email || account&.email
  end
  
  def primary_phone
    contact&.phone || account&.phone
  end
  
  # Inventory management methods
  def has_inventory_items?
    quote_inventory_usages.any?
  end
  
  def inventory_items_used?
    quote_inventory_usages.any? && quote_inventory_usages.all?(&:used?)
  end
  
  def inventory_items_partially_used?
    quote_inventory_usages.used.any? && quote_inventory_usages.not_used.any?
  end
  
  def mark_all_inventory_used!(user)
    results = { success: [], failed: [] }
    
    quote_inventory_usages.not_used.each do |usage|
      if usage.mark_as_used!(user)
        results[:success] << usage.id
      else
        results[:failed] << { id: usage.id, part_id: usage.part_id, error: 'Failed to mark as used' }
      end
    end
    
    results
  end
  
  private
  
  def serialize_items(items_array)
    return [] if items_array.nil?
    
    items_array.map do |item|
      next item unless item.is_a?(Hash)
      
      serialized_item = {}
      item.each do |key, value|
        # Convert snake_case to camelCase
        camel_key = key.to_s.camelize(:lower)
        serialized_item[camel_key] = value
      end
      serialized_item
    end
  end
  
  def generate_quote_number
    self.quote_number ||= loop do
      number = "QUO-#{Time.current.year}-#{SecureRandom.hex(4).upcase}"
      break number unless self.class.exists?(quote_number: number)
    end
  end
  
  def generate_public_token
    self.public_token ||= loop do
      token = SecureRandom.urlsafe_base64(32)
      break token unless self.class.exists?(public_token: token)
    end
  end
  
  def calculate_totals
    return unless items.is_a?(Array) && items.any?
    
    # Calculate subtotal from items (sum of all item totals)
    calculated_subtotal = 0.0
    calculated_tax = 0.0
    effective_tax_rate = (self.tax_rate || 0).to_f
    
    items.each do |item|
      next unless item.is_a?(Hash)
      
      quantity = (item['quantity'] || item[:quantity]).to_f
      unit_price = (item['unitPrice'] || item['unit_price'] || item[:unitPrice] || item[:unit_price]).to_f
      discount = (item['discount'] || item[:discount]).to_f
      discount_type = (item['discountType'] || item['discount_type'] || item[:discountType] || item[:discount_type]).to_s
      
      item_subtotal = quantity * unit_price
      item_discount = discount_type == 'percentage' ? item_subtotal * (discount / 100.0) : discount
      item_total = item_subtotal - item_discount
      calculated_subtotal += item_total
      
      # Per-item taxable check — if the item has a 'taxable' flag, use it
      item_taxable = item['taxable'] || item[:taxable]
      if item_taxable == true || item_taxable == 'true'
        # Use item-level tax_rate if present, otherwise fall back to quote-level
        item_tax_rate = (item['taxRate'] || item['tax_rate'] || item[:taxRate] || item[:tax_rate])&.to_f
        rate = (item_tax_rate.present? && item_tax_rate > 0) ? item_tax_rate : effective_tax_rate
        calculated_tax += item_total * (rate / 100.0)
      end
    end
    
    # Only recalculate if frontend didn't send explicit values
    # Frontend sends subtotal/tax/total — use them if present and reasonable
    self.subtotal = self.subtotal.present? && self.subtotal > 0 ? self.subtotal : calculated_subtotal
    self.tax = self.tax.present? && self.tax >= 0 ? self.tax : calculated_tax
    self.total = self.subtotal + self.tax
  end
  
  def check_expiration
    if valid_until.present? && valid_until < Date.current && %w[draft sent viewed].include?(status)
      self.status = 'expired'
    end
  end
  
  def items_must_be_array
    return if items.nil?
    errors.add(:items, 'must be an array') unless items.is_a?(Array)
  end
  
  def valid_until_must_be_future
    if valid_until.present? && valid_until < Date.current
      errors.add(:valid_until, 'must be a future date')
    end
  end

  # Fire custom lifecycle webhook events on status transitions
  # WebhookNotifiable handles generic quote.created/updated/deleted
  # This adds quote.approved and quote.rejected for specific transitions.
  def fire_lifecycle_webhooks
    event = case status
            when 'accepted' then 'quote.approved'
            when 'rejected' then 'quote.rejected'
            end

    return unless event

    WebhookService.fire(
      company_id: company_id,
      event: event,
      payload: webhook_payload
    )
  rescue => e
    Rails.logger.error "[Quote] Failed to fire lifecycle webhook #{event}: #{e.message}"
  end
end
