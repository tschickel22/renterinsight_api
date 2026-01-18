# frozen_string_literal: true

class Manufacturer < ApplicationRecord
  # Note: Removed Customizable concern - not needed for manufacturers yet
  
  # Associations
  belongs_to :company, optional: true  # Optional for global warranty manufacturers
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true
  
  has_many :parts, dependent: :restrict_with_error
  has_many :warranty_claims
  has_many :manufacturer_ar_transactions
  has_many :location_manufacturers
  has_many :company_manufacturers
  
  # Validations
  validates :name, presence: true, length: { maximum: 255 }
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :contact_phone, length: { maximum: 20 }, allow_blank: true
  
  # Company-scoped manufacturers must have unique name/code
  validates :code, uniqueness: { scope: :company_id, conditions: -> { where(is_deleted: false) }, allow_nil: true }, if: :company_id?
  validates :name, uniqueness: { scope: :company_id, conditions: -> { where(is_deleted: false) } }, if: :company_id?
  
  # Scopes
  scope :active, -> { where(active: true).where('is_deleted = ? OR is_deleted IS NULL', false) }
  scope :for_company, ->(company_id) { where(company_id: company_id).where('is_deleted = ? OR is_deleted IS NULL', false) }
  scope :global_warranty, -> { where(company_id: nil).where('is_deleted IS NULL OR is_deleted = ?', false) }
  scope :by_name, -> { order(:name) }
  
  # Callbacks
  before_validation :normalize_fields
  
  # Soft delete
  def soft_delete!
    if parts.where('is_deleted = ? OR is_deleted IS NULL', false).exists?
      errors.add(:base, 'Cannot delete manufacturer with associated parts')
      raise ActiveRecord::RecordInvalid, self
    end
    update!(is_deleted: true, deleted_at: Time.current, active: false)
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  # Display helpers
  def display_name
    code.present? ? "#{name} (#{code})" : name
  end
  
  def full_address
    parts = [address_line1, address_line2, city, state, zip_code, country].compact.reject(&:blank?)
    parts.any? ? parts.join(', ') : nil
  end
  
  def as_json(options = {})
    super(options.merge(
      only: [:id, :name, :code, :contact_name, :contact_email, :contact_phone, :website, 
             :active, :created_at, :updated_at, :company_id],
      methods: [:display_name, :full_address]
    ))
  end
  
  private
  
  def normalize_fields
    self.name = name&.strip
    self.code = code&.strip&.upcase if code.present?
    self.contact_email = contact_email&.strip&.downcase if contact_email.present?
    self.contact_phone = contact_phone&.strip if contact_phone.present?
    self.contact_name = contact_name&.strip if contact_name.present?
    self.city = city&.strip&.titleize if city.present?
    self.state = state&.strip&.upcase if state.present?
    self.zip_code = zip_code&.strip if zip_code.present?
    self.country = country&.strip&.upcase if country.present?
  end
end
