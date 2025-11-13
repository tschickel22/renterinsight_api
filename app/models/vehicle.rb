# frozen_string_literal: true

class Vehicle < ApplicationRecord
  # Associations
  belongs_to :company, optional: true
  has_many :deals, dependent: :nullify
  has_many :quotes, dependent: :nullify
  has_many :listings, dependent: :destroy
  has_many :note_records, as: :entity, class_name: 'Note', dependent: :destroy

  # Vehicle types
  TYPES = %w[rv manufactured_home].freeze
  STATUSES = %w[available reserved sold pending service].freeze
  CONDITIONS = %w[new used].freeze

  # Validations
  validates :inventory_id, presence: true, uniqueness: { scope: :company_id }
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
    validates :serial_number, presence: true, uniqueness: { scope: :company_id }
    validates :bedrooms, :bathrooms, presence: true
    # Bedrooms and bathrooms are validated in normalize_bedroom_bathroom_values callback
  end

  # Scopes
  scope :active, -> { where(is_deleted: false) }
  scope :available, -> { active.where(status: 'available') }
  scope :reserved, -> { active.where(status: 'reserved') }
  scope :sold, -> { active.where(status: 'sold') }
  scope :pending, -> { active.where(status: 'pending') }
  scope :by_type, ->(type) { where(listing_type: type) }
  scope :by_status, ->(status) { where(status: status) }
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

  # Callbacks
  before_validation :normalize_fields
  before_validation :normalize_bedroom_bathroom_values  # FIX: Added to handle "4+" values
  before_validation :generate_inventory_id, on: :create

  # Soft delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current)
  end

  def restore!
    update!(is_deleted: false, deleted_at: nil)
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

  def price_display
    sale_price || rent_price
  end

  def is_rv?
    listing_type == 'rv'
  end

  def is_manufactured_home?
    listing_type == 'manufactured_home'
  end

  private

  def normalize_fields
    self.make = make&.titleize
    self.model = model&.titleize
    self.status = status&.downcase
    self.listing_type = listing_type&.downcase
  end

  # FIX: New method to handle "4+" bedroom/bathroom values
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
end
