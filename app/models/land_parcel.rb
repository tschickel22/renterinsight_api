# frozen_string_literal: true

class LandParcel < ApplicationRecord
  # Associations
  belongs_to :company
  has_many :note_records, as: :entity, class_name: 'Note', dependent: :destroy
  
  # Constants
  ZONING_TYPES = %w[residential commercial agricultural industrial mixed_use].freeze
  STATUSES = %w[available pending sold under_contract withdrawn].freeze
  
  # Validations
  validates :parcel_number, presence: true, uniqueness: { scope: :company_id }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :zoning_type, inclusion: { in: ZONING_TYPES }, allow_nil: true
  validates :acreage, numericality: { greater_than: 0 }, allow_nil: true
  validates :price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :latitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }, allow_nil: true
  validates :longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }, allow_nil: true
  
  # Scopes
  scope :active, -> { where(is_deleted: false) }
  scope :available, -> { active.where(status: 'available') }
  scope :sold, -> { active.where(status: 'sold') }
  scope :pending, -> { active.where(status: 'pending') }
  scope :under_contract, -> { active.where(status: 'under_contract') }
  scope :by_status, ->(status) { where(status: status) }
  scope :by_zoning, ->(zoning) { where(zoning_type: zoning) }
  scope :by_city, ->(city) { where('LOWER(city) = ?', city.to_s.downcase) }
  scope :by_state, ->(state) { where(state: state) }
  scope :by_price_range, ->(min, max) { where(price: min..max) }
  scope :by_acreage_range, ->(min, max) { where(acreage: min..max) }
  scope :search, ->(query) do
    operator = connection.adapter_name.downcase.include?('sqlite') ? 'LIKE' : 'ILIKE'
    where(
      "parcel_number #{operator} ? OR name #{operator} ? OR address #{operator} ? OR city #{operator} ? OR description #{operator} ?",
      "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%"
    )
  end
  scope :recent, -> { order(created_at: :desc) }
  
  # Callbacks
  before_validation :normalize_fields
  before_validation :calculate_price_per_acre
  before_validation :generate_parcel_number, on: :create
  
  # Soft delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current)
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  # Display helpers
  def display_name
    name.present? ? name : "Parcel #{parcel_number}"
  end
  
  def full_address
    parts = [address, city, state, zip].compact.reject(&:blank?)
    parts.any? ? parts.join(', ') : nil
  end
  
  def coordinates
    return nil unless latitude.present? && longitude.present?
    { latitude: latitude.to_f, longitude: longitude.to_f }
  end
  
  def has_utilities?
    utilities.present? && utilities.any? { |_k, v| v == true }
  end
  
  def utility_list
    return [] unless utilities.present?
    utilities.select { |_k, v| v == true }.keys.map(&:to_s)
  end
  
  private
  
  def normalize_fields
    self.state = state&.upcase
    self.status = status&.downcase
    self.zoning_type = zoning_type&.downcase
  end
  
  def calculate_price_per_acre
    if price.present? && acreage.present? && acreage > 0
      self.price_per_acre = price / acreage
    end
  end
  
  def generate_parcel_number
    return if parcel_number.present?
    
    prefix = 'LP'
    timestamp = Time.current.strftime('%Y%m%d')
    random = SecureRandom.hex(3).upcase
    
    self.parcel_number = "#{prefix}-#{timestamp}-#{random}"
  end
end
