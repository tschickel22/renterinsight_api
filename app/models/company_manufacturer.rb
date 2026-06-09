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
  
  # Delegations — prefixed accessors for the GLOBAL factory defaults
  # (manufacturer_contact_email, etc.). This company's own override contact lives
  # in the company_manufacturers columns (contact_name/email/phone).
  delegate :name, :industry_type, :contact_email, :contact_phone, :website,
           :supports_rv?, :supports_manufactured_homes?, to: :manufacturer, prefix: true

  # Instance Methods

  # Effective contact = this company's override if set, else the global factory
  # default. Used for warranty routing and display.
  def effective_contact_name
    contact_name.presence || manufacturer&.contact_name
  end

  def effective_contact_email
    contact_email.presence || manufacturer&.contact_email
  end

  def effective_contact_phone
    contact_phone.presence || manufacturer&.contact_phone
  end

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
