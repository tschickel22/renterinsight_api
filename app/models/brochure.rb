# frozen_string_literal: true

class Brochure < ApplicationRecord
  # Associations
  belongs_to :company

  # Validations
  validates :title, presence: true
  validates :public_id, presence: true, uniqueness: true
  validates :company_id, presence: true
  validates :status, inclusion: { in: %w[active inactive archived] }
  
  # Callbacks
  before_validation :generate_public_id, on: :create
  before_validation :ensure_vehicle_ids_is_array
  before_validation :ensure_template_data_is_hash

  # Scopes
  scope :active, -> { where(is_deleted: false, status: 'active') }
  scope :inactive, -> { where(is_deleted: false, status: 'inactive') }
  scope :archived, -> { where(is_deleted: false, status: 'archived') }
  scope :public_brochures, -> { where(is_public: true, is_deleted: false, status: 'active') }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_template, ->(template_name) { where(template_name: template_name) }
  scope :search, ->(query) do
    operator = connection.adapter_name.downcase.include?('sqlite') ? 'LIKE' : 'ILIKE'
    where(
      "title #{operator} ? OR description #{operator} ? OR template_name #{operator} ?",
      "%#{query}%", "%#{query}%", "%#{query}%"
    )
  end

  # Get vehicles for this brochure
  def vehicles
    return [] if vehicle_ids.blank? || !vehicle_ids.is_a?(Array)
    company.vehicles.where(id: vehicle_ids)
  end

  # Increment tracking counters
  def increment_view_count!
    increment!(:view_count)
  end

  def increment_share_count!
    increment!(:share_count)
  end

  def increment_download_count!
    increment!(:download_count)
  end

  # Soft delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current, status: 'archived')
  end

  def restore!
    update!(is_deleted: false, deleted_at: nil, status: 'active')
  end

  # Public URL
  def public_url(base_url)
    "#{base_url}/b/#{public_id}"
  end

  # Check if brochure has vehicles
  def has_vehicles?
    vehicle_ids.present? && vehicle_ids.any?
  end

  # Get vehicle count
  def vehicle_count
    vehicle_ids&.length || 0
  end

  private

  def generate_public_id
    return if public_id.present?
    
    loop do
      self.public_id = SecureRandom.urlsafe_base64(12)
      break unless Brochure.exists?(public_id: public_id)
    end
  end

  def ensure_vehicle_ids_is_array
    self.vehicle_ids = [] if vehicle_ids.nil?
    self.vehicle_ids = [vehicle_ids] if vehicle_ids.is_a?(String)
  end

  def ensure_template_data_is_hash
    self.template_data = {} if template_data.nil?
  end
end
