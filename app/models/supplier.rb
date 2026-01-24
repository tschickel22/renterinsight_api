# frozen_string_literal: true

class Supplier < ApplicationRecord
  include Customizable
  
  # Associations
  belongs_to :company
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true
  
  has_many :supplier_parts, dependent: :destroy
  has_many :parts, through: :supplier_parts
  # has_many :purchase_orders, dependent: :restrict_with_error # Phase 2A
  
  # Validations
  validates :company_id, presence: true
  validates :name, presence: true, length: { maximum: 255 }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :phone, length: { maximum: 20 }, allow_blank: true
  validates :code, uniqueness: { scope: :company_id, conditions: -> { where(is_deleted: false) }, allow_nil: true }
  
  # Scopes
  scope :active, -> { where(active: true, is_deleted: false) }
  scope :for_company, ->(company_id) { where(company_id: company_id, is_deleted: false) }
  scope :by_name, -> { order(:name) }
  
  # Callbacks
  before_validation :normalize_fields
  
  # Soft delete
  def soft_delete!
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
      only: [:id, :name, :code, :account_number, :contact_name, :email, :phone, :website, :payment_terms, 
             :default_lead_time_days, :active, :created_at, :updated_at],
      methods: [:display_name, :full_address]
    ))
  end
  
  private
  
  def normalize_fields
    self.name = name&.strip
    self.code = code&.strip&.upcase if code.present?
    self.email = email&.strip&.downcase if email.present?
    self.phone = phone&.strip if phone.present?
    self.city = city&.strip&.titleize if city.present?
    self.state = state&.strip&.upcase if state.present?
    self.zip_code = zip_code&.strip if zip_code.present?
    self.country = country&.strip&.upcase if country.present?
  end
end
