# frozen_string_literal: true

class Manufacturer < ApplicationRecord
  # Note: Removed Customizable concern - not needed for manufacturers yet
  
  # Associations
  # NOTE: manufacturers is a global table (no company_id column). Per-company
  # access is modeled through the company_manufacturers join table.
  has_many :parts, dependent: :restrict_with_error
  has_many :warranty_claims
  has_many :manufacturer_ar_transactions
  has_many :location_manufacturers
  has_many :company_manufacturers

  # Configurator associations
  has_many :factories, dependent: :destroy
  has_many :floor_plans, dependent: :destroy
  
  # Validations
  validates :name, presence: true, length: { maximum: 255 }
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :contact_phone, length: { maximum: 20 }, allow_blank: true
  # code has a partial unique index (where code IS NOT NULL); mirror it here.
  validates :code, uniqueness: { allow_blank: true }

  # Scopes
  scope :active, -> { where(active: true) }
  scope :by_name, -> { order(:name) }
  scope :alphabetical, -> { order(:name) }
  scope :scraper_enabled, -> { where(scraper_enabled: true) }
  
  # Callbacks
  before_validation :normalize_fields
  
  # Soft delete (deactivate since we don't have is_deleted column)
  def soft_delete!
    if parts.where('is_deleted = ? OR is_deleted IS NULL', false).exists?
      errors.add(:base, 'Cannot delete manufacturer with associated parts')
      raise ActiveRecord::RecordInvalid, self
    end
    update!(active: false)
  end
  
  def deactivate!
    update!(active: false)
  end
  
  def activate!
    update!(active: true)
  end
  
  # Display helpers
  def display_name
    code.present? ? "#{name} (#{code})" : name
  end
  
  def as_json(options = {})
    super(options.merge(
      only: [:id, :name, :code, :contact_email, :contact_phone, :website,
             :active, :created_at, :updated_at],
      methods: [:display_name]
    ))
  end
  
  private
  
  def normalize_fields
    self.name = name&.strip
    self.code = code&.strip&.upcase if code.present?
    self.contact_email = contact_email&.strip&.downcase if contact_email.present?
    self.contact_phone = contact_phone&.strip if contact_phone.present?
  end
end
