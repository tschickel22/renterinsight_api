# frozen_string_literal: true

# == Schema Information
#
# Table name: manufacturers
#
#  id                  :bigint           not null, primary key
#  name                :string           not null
#  industry_type       :string           not null
#  contact_email       :string
#  contact_phone       :string
#  website             :string
#  oem_codes           :jsonb            default({})
#  has_portal_access   :boolean          default(FALSE), not null
#  portal_url          :string
#  active              :boolean          default(TRUE), not null
#  notes               :text
#  metadata            :jsonb            default({})
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#

class Manufacturer < ApplicationRecord
  # This is a PLATFORM-LEVEL table (no company_id)
  # All companies share the same manufacturer list
  
  INDUSTRY_TYPES = %w[rv manufactured_home both].freeze
  
  # Associations
  has_many :warranty_claims, dependent: :restrict_with_error
  has_many :manufacturer_ar_transactions, dependent: :restrict_with_error
  
  # Company Associations (through join table)
  has_many :company_manufacturers, dependent: :destroy
  has_many :companies, through: :company_manufacturers
  
  # Location Associations (through join table)
  has_many :location_manufacturers, dependent: :destroy
  has_many :locations, through: :location_manufacturers
  
  # Validations
  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :industry_type, presence: true, inclusion: { in: INDUSTRY_TYPES }
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  # Website validation - accept domains with or without protocol
  validates :website, format: { 
    with: /\A(https?:\/\/)?(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&\/\/=]*)\z/
  }, allow_blank: true
  
  # Serialize JSONB columns
  attribute :oem_codes, :json, default: {}
  attribute :metadata, :json, default: {}
  
  # Scopes
  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :for_industry, ->(industry_type) { where(industry_type: industry_type) }
  scope :rv_manufacturers, -> { where(industry_type: ['rv', 'both']) }
  scope :mh_manufacturers, -> { where(industry_type: ['manufactured_home', 'both']) }
  scope :with_portal, -> { where(has_portal_access: true) }
  scope :alphabetical, -> { order(:name) }
  scope :search, ->(query) do
    where('name ILIKE ? OR contact_email ILIKE ?', "%#{query}%", "%#{query}%")
  end
  
  # Callbacks
  before_save :normalize_name
  before_save :normalize_website
  
  # Instance Methods
  
  def display_name
    name
  end
  
  def supports_rv?
    ['rv', 'both'].include?(industry_type)
  end
  
  def supports_manufactured_homes?
    ['manufactured_home', 'both'].include?(industry_type)
  end
  
  def deactivate!
    update!(active: false)
  end
  
  def activate!
    update!(active: true)
  end
  
  # Get dealer code for a specific company (if stored in oem_codes)
  def dealer_code_for(company)
    return nil unless oem_codes.is_a?(Hash)
    oem_codes.dig(company.id.to_s, 'dealer_code')
  end
  
  # Set dealer code for a specific company
  def set_dealer_code_for(company, code)
    self.oem_codes ||= {}
    self.oem_codes[company.id.to_s] ||= {}
    self.oem_codes[company.id.to_s]['dealer_code'] = code
    save
  end
  
  # Statistics
  def total_claims_count
    warranty_claims.count
  end
  
  def active_claims_count
    warranty_claims.where(status: ['submitted', 'under_review']).count
  end
  
  def approved_claims_count
    warranty_claims.where(status: 'approved').count
  end
  
  def total_ar_outstanding
    manufacturer_ar_transactions.where(status: ['open', 'partial']).sum(:amount_outstanding)
  end
  
  private
  
  def normalize_name
    self.name = name.strip if name.present?
  end
  
  def normalize_website
    return if website.blank?
    
    # Strip whitespace
    self.website = website.strip
    
    # Add https:// if no protocol specified
    unless website.match?(/\Ahttps?:\/\//i)
      self.website = "https://#{website}"
    end
  end
end
