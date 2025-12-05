# frozen_string_literal: true

# == Schema Information
#
# Table name: location_manufacturers
#
#  id              :bigint           not null, primary key
#  location_id     :bigint           not null
#  manufacturer_id :bigint           not null
#  dealer_code     :string
#  active          :boolean          default(TRUE), not null
#  notes           :text
#  metadata        :jsonb            default({})
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#

class LocationManufacturer < ApplicationRecord
  # Associations
  belongs_to :location
  belongs_to :manufacturer
  
  # Validations
  validates :location_id, presence: true
  validates :manufacturer_id, presence: true
  validates :location_id, uniqueness: { scope: :manufacturer_id, message: "already has this manufacturer" }
  
  # Serialize JSONB
  attribute :metadata, :json, default: {}
  
  # Scopes
  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :with_dealer_code, -> { where.not(dealer_code: [nil, '']) }
  scope :for_industry, ->(industry_type) do
    joins(:manufacturer).where(manufacturers: { industry_type: industry_type })
  end
  scope :alphabetical, -> { joins(:manufacturer).order('manufacturers.name') }
  
  # Delegations
  delegate :name, :industry_type, :contact_email, :contact_phone, :website, 
           :supports_rv?, :supports_manufactured_homes?, to: :manufacturer, prefix: true
  
  # Instance Methods
  
  def display_name
    manufacturer.name
  end
  
  def has_dealer_code?
    dealer_code.present?
  end
  
  def deactivate!
    update!(active: false)
  end
  
  def activate!
    update!(active: true)
  end
  
  # Get effective dealer code (location-specific or fallback to company)
  def self.effective_dealer_code_for(location, manufacturer)
    # Try location-specific first
    location_manufacturer = location.location_manufacturers.find_by(manufacturer_id: manufacturer.id)
    return location_manufacturer.dealer_code if location_manufacturer&.dealer_code.present?
    
    # Fallback to company-level
    company_manufacturer = location.company.company_manufacturers.find_by(manufacturer_id: manufacturer.id)
    company_manufacturer&.dealer_code
  end
end
