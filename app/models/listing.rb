# frozen_string_literal: true

class Listing < ApplicationRecord
  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :vehicle
  
  # Statuses
  STATUSES = %w[draft active inactive sold rented].freeze
  OFFER_TYPES = %w[sale rent both].freeze
  RENT_PERIODS = %w[monthly weekly daily].freeze
  PACKAGE_TYPES = %w[package land_only home_only].freeze
  LOCATION_TYPES = %w[community private_land dealer_lot].freeze
  
  # Validations
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :offer_type, presence: true, inclusion: { in: OFFER_TYPES }
  validates :rent_period, inclusion: { in: RENT_PERIODS }, allow_nil: true
  
  # Price validations
  with_options if: -> { offer_type.in?(%w[sale both]) } do
    validates :sale_price, presence: true, numericality: { greater_than: 0 }
  end
  
  with_options if: -> { offer_type.in?(%w[rent both]) } do
    validates :rent_price, presence: true, numericality: { greater_than: 0 }
    validates :rent_period, presence: true
  end
  
  # Description validation
  validates :description, length: { minimum: 20, maximum: 5000 }, allow_blank: true
  
  # Scopes
  scope :active, -> { where(is_deleted: false) }
  scope :published, -> { active.where(status: 'active').where.not(published_at: nil) }
  scope :draft, -> { active.where(status: 'draft') }
  scope :by_status, ->(status) { where(status: status) }
  scope :by_offer_type, ->(type) { where(offer_type: type) }
  scope :for_sale, -> { where(offer_type: %w[sale both]) }
  scope :for_rent, -> { where(offer_type: %w[rent both]) }
  scope :recent, -> { order(created_at: :desc) }
  scope :recently_published, -> { published.order(published_at: :desc) }
  
  # Callbacks
  before_validation :normalize_fields
  before_save :ensure_published_at
  
  # Soft delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current, status: 'inactive')
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  # Status helpers
  def draft?
    status == 'draft'
  end
  
  def active?
    status == 'active'
  end
  
  def inactive?
    status == 'inactive'
  end
  
  def sold?
    status == 'sold'
  end
  
  def rented?
    status == 'rented'
  end
  
  def published?
    published_at.present? && active?
  end
  
  # Publishing
  def publish!
    return false unless valid_for_publishing?
    
    update!(
      status: 'active',
      published_at: Time.current
    )
  end
  
  def unpublish!
    update!(status: 'inactive')
  end
  
  def valid_for_publishing?
    # Must have description
    return false if description.blank?
    
    # Must have appropriate pricing
    case offer_type
    when 'sale'
      return false if sale_price.blank? || sale_price <= 0
    when 'rent'
      return false if rent_price.blank? || rent_price <= 0 || rent_period.blank?
    when 'both'
      return false if (sale_price.blank? || sale_price <= 0) && 
                      (rent_price.blank? || rent_price <= 0 || rent_period.blank?)
    end
    
    # Vehicle must exist and be available
    return false unless vehicle.present?
    
    true
  end
  
  # Display helpers
  def display_name
    vehicle&.display_name || "Listing ##{id}"
  end
  
  def price_display
    parts = []
    parts << "$#{sale_price.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}" if sale_price.present?
    parts << "$#{rent_price.to_i}/#{rent_period}" if rent_price.present? && rent_period.present?
    parts.join(' or ')
  end
  
  def full_location
    vehicle&.full_location
  end
  
  # Feature helpers
  def feature_list
    features_array = []
    features_array << 'Garage' if has_garage?
    features_array << 'Fireplace' if has_fireplace?
    features_array << 'Deck' if has_deck?
    features_array << 'Shed' if has_shed?
    features_array << 'Appliances' if has_appliances?
    features_array << 'A/C' if has_ac?
    features_array << 'Furnished' if is_furnished?
    features_array << 'Pets Allowed' if pets_allowed?
    features_array
  end
  
  # Syndication helpers
  def mark_synced!
    update(last_synced_at: Time.current)
  end
  
  def needs_sync?
    last_synced_at.nil? || updated_at > last_synced_at
  end
  
  # MH Village data completeness
  def mh_village_ready?
    return false unless vehicle.is_manufactured_home?
    return false unless published?
    
    # Required fields for MH Village
    required_fields = [
      vehicle.year,
      vehicle.make,
      vehicle.model,
      vehicle.serial_number,
      vehicle.length,
      vehicle.width,
      vehicle.bedrooms,
      vehicle.bathrooms,
      description,
      sale_price || rent_price
    ]
    
    required_fields.all?(&:present?)
  end
  
  # MITS feed data completeness
  def mits_ready?
    return false unless published?
    return false unless offer_type.in?(%w[rent both])
    
    # Required fields for MITS XML
    required_fields = [
      property_name,
      vehicle&.bedrooms,
      vehicle&.bathrooms,
      rent_price,
      description
    ]
    
    required_fields.all?(&:present?) && 
      (latitude.present? || vehicle&.location_city.present?)
  end
  
  # Helper for MITS property grouping
  def mits_property_id
    property_name&.parameterize || "property-#{company_id}"
  end
  
  # Helper for office hours JSON structure
  def formatted_office_hours
    return [] if office_hours.blank?
    
    office_hours.is_a?(Array) ? office_hours : []
  end
  
  # Helper for parking details
  def formatted_parking
    return {} if parking_details.blank?
    
    parking_details.is_a?(Hash) ? parking_details : {}
  end
  
  # Helper for pet policy
  def formatted_pet_policy
    return {} if pet_policy.blank?
    
    pet_policy.is_a?(Hash) ? pet_policy : {}
  end
  
  # Helper for property amenities
  def formatted_property_amenities
    return [] if property_amenities.blank?
    
    property_amenities.is_a?(Array) ? property_amenities : []
  end
  
  # Helper for unit amenities
  def formatted_unit_amenities
    return [] if unit_amenities.blank?
    
    unit_amenities.is_a?(Array) ? unit_amenities : []
  end
  
  private
  
  def normalize_fields
    self.status = status&.downcase
    self.offer_type = offer_type&.downcase
    self.rent_period = rent_period&.downcase if rent_period.present?
  end
  
  def ensure_published_at
    # Automatically set published_at when status is active
    if status == 'active' && published_at.nil?
      self.published_at = Time.current
    end
  end
end
