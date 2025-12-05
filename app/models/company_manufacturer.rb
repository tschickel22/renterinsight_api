# frozen_string_literal: true

# == Schema Information
#
# Table name: company_manufacturers
#
#  id              :bigint           not null, primary key
#  company_id      :bigint           not null
#  manufacturer_id :bigint           not null
#  dealer_code     :string
#  active          :boolean          default(TRUE), not null
#  notes           :text
#  metadata        :jsonb            default({})
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#

class CompanyManufacturer < ApplicationRecord
  # Associations
  belongs_to :company
  belongs_to :manufacturer
  
  # Validations
  validates :company_id, presence: true
  validates :manufacturer_id, presence: true
  validates :company_id, uniqueness: { scope: :manufacturer_id, message: "already has this manufacturer" }
  
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
end
