# frozen_string_literal: true

class Bin < ApplicationRecord
  include Customizable
  
  # Associations
  belongs_to :location
  has_many :stock_balances, dependent: :destroy
  has_many :parts, through: :stock_balances
  
  # Validations
  validates :location_id, presence: true
  validates :bin_code, presence: true, length: { maximum: 50 }
  validates :bin_code, uniqueness: { scope: :location_id, conditions: -> { where(is_deleted: false) } }
  validates :bin_type, inclusion: { in: %w[standard picking receiving quarantine returns] }
  
  # Scopes
  scope :active, -> { where(active: true, is_deleted: false) }
  scope :for_location, ->(location_id) { where(location_id: location_id, is_deleted: false) }
  scope :defaults, -> { where(is_default: true) }
  scope :by_code, -> { order(:bin_code) }
  scope :by_type, ->(type) { where(bin_type: type) }
  
  # Callbacks
  before_validation :normalize_fields
  before_save :ensure_single_default
  
  # Soft delete
  def soft_delete!
    # Check if bin has stock
    if stock_balances.where('on_hand > 0').exists?
      errors.add(:base, "Cannot delete bin with inventory on hand")
      raise ActiveRecord::RecordInvalid, self
    end
    
    update!(is_deleted: true, deleted_at: Time.current, active: false)
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  # Display helpers
  def display_name
    label.present? ? "#{bin_code} (#{label})" : bin_code
  end
  
  def full_name
    "#{location.name} - #{display_name}"
  end
  
  # Inventory helpers
  def parts_count
    stock_balances.where('on_hand > 0').count
  end
  
  def total_units
    stock_balances.sum(:on_hand)
  end
  
  def has_stock?
    stock_balances.where('on_hand > 0').exists?
  end
  
  def as_json(options = {})
    super(options.merge(
      only: [:id, :location_id, :bin_code, :label, :bin_type, :is_default, :active, 
             :created_at, :updated_at],
      methods: [:display_name, :parts_count, :total_units],
      include: {
        location: { only: [:id, :name, :code] }
      }
    ))
  end
  
  private
  
  def normalize_fields
    self.bin_code = bin_code&.strip&.upcase if bin_code.present?
    self.label = label&.strip if label.present?
  end
  
  def ensure_single_default
    return unless is_default_changed? && is_default?
    
    # Unset other default bins for this location
    Bin.where(location_id: location_id, is_default: true)
       .where.not(id: id)
       .update_all(is_default: false)
  end
end
