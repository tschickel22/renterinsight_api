# frozen_string_literal: true

class Quote < ApplicationRecord
  include Communicable
  include LocationAware
  # Quote Statuses
  STATUSES = %w[draft sent viewed accepted rejected expired].freeze
  
  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  belongs_to :vehicle, optional: true  # Added vehicle relationship
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
  scope :search, ->(query) do
    where('quote_number ILIKE ? OR notes ILIKE ?', "%#{query}%", "%#{query}%")
  end
  scope :recent, -> { order(created_at: :desc) }
  
  # Callbacks
  before_validation :generate_quote_number, on: :create
  before_validation :generate_public_token, on: :create
  before_validation :calculate_totals
  before_validation :check_expiration
  
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
      'status' => status,
      'subtotal' => subtotal,
      'tax' => tax,
      'total' => total,
      'notes' => notes,
      'sent_at' => sent_at,
      'last_sent_at' => last_sent_at,
      'resend_count' => resend_count || 0,
      'viewed_at' => viewed_at,
      'accepted_at' => accepted_at,
      'rejected_at' => rejected_at,
      
      # Handle items - convert keys from snake_case to camelCase for frontend
      'items' => serialize_items(items),
      'lineItems' => serialize_items(items),
      
      # Add account, contact, and vehicle names
      'accountName' => account&.name,
      'contactName' => contact ? "#{contact.first_name} #{contact.last_name}".strip : nil,
      'vehicleName' => vehicle&.display_name,
      
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
    
    # Calculate subtotal from items
    self.subtotal = items.sum do |item|
      next 0 unless item.is_a?(Hash)
      
      quantity = (item['quantity'] || item[:quantity]).to_f
      unit_price = (item['unitPrice'] || item['unit_price'] || item[:unitPrice] || item[:unit_price]).to_f
      quantity * unit_price
    end
    
    # Tax is set separately or calculated
    self.tax ||= 0.0
    
    # Calculate total
    self.total = subtotal + tax
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
end
