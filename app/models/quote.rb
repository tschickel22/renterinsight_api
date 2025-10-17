# frozen_string_literal: true

class Quote < ApplicationRecord
  include Communicable
  # Quote Statuses
  STATUSES = %w[draft sent viewed accepted rejected expired].freeze
  
  # Associations
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  has_many :note_records, as: :entity, class_name: 'Note', dependent: :destroy
  
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
  scope :valid, -> { where('valid_until IS NULL OR valid_until >= ?', Date.current) }
  scope :expired, -> { where('valid_until < ?', Date.current) }
  scope :search, ->(query) do
    where('quote_number ILIKE ? OR notes ILIKE ?', "%#{query}%", "%#{query}%")
  end
  scope :recent, -> { order(created_at: :desc) }
  
  # Callbacks
  before_validation :generate_quote_number, on: :create
  before_validation :calculate_totals
  before_validation :check_expiration
  
  # Soft Delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current)
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  # Status transitions
  def send!
    return false unless draft?
    
    update!(
      status: 'sent',
      sent_at: Time.current
    )
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
  
  # JSON serialization
  def as_json(options = {})
    # Build JSON manually to avoid JSONB serialization issues
    json = {
      'id' => id.to_s,
      'quote_number' => quote_number,
      'accountId' => account_id&.to_s,
      'contactId' => contact_id&.to_s,
      'customerId' => customer_id,
      'vehicleId' => vehicle_id,
      'status' => status,
      'subtotal' => subtotal,
      'tax' => tax,
      'total' => total,
      'notes' => notes,
      'sent_at' => sent_at,
      'viewed_at' => viewed_at,
      'accepted_at' => accepted_at,
      'rejected_at' => rejected_at,
      
      # Handle items - they're already hashes from JSONB
      'items' => items || [],
      'lineItems' => items || [],
      
      # Add account and contact names
      'accountName' => account&.name,
      'contactName' => contact ? "#{contact.first_name} #{contact.last_name}".strip : nil,
      
      # Format dates
      'validUntil' => valid_until,
      'createdAt' => created_at,
      'updatedAt' => updated_at
    }
    
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
    
    json
  end
  
  private
  
  def generate_quote_number
    self.quote_number ||= loop do
      number = "QUO-#{Time.current.year}-#{SecureRandom.hex(4).upcase}"
      break number unless self.class.exists?(quote_number: number)
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
