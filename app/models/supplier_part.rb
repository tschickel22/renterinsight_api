# frozen_string_literal: true

class SupplierPart < ApplicationRecord
  include Customizable
  
  # Associations
  belongs_to :supplier
  belongs_to :part
  
  # Validations
  validates :supplier_id, presence: true
  validates :part_id, presence: true
  validates :supplier_id, uniqueness: { scope: :part_id }
  validates :minimum_order_quantity, numericality: { greater_than: 0, allow_nil: true }
  validates :lead_time_days, numericality: { only_integer: true, greater_than_or_equal_to: 0, allow_nil: true }
  
  # Callbacks
  before_save :ensure_single_preferred
  
  # Scopes
  scope :preferred, -> { where(preferred: true) }
  scope :by_cost, -> { order(last_cost: :asc) }
  scope :by_lead_time, -> { order(lead_time_days: :asc) }
  
  # Display helpers
  def display_name
    "#{supplier.name} - #{part.sku}"
  end
  
  def as_json(options = {})
    super(options.merge(
      only: [:id, :supplier_id, :part_id, :supplier_sku, :last_cost, :lead_time_days, 
             :minimum_order_quantity, :preferred, :created_at, :updated_at],
      include: {
        supplier: { only: [:id, :name, :code] },
        part: { only: [:id, :sku, :name] }
      }
    ))
  end
  
  private
  
  def ensure_single_preferred
    return unless preferred_changed? && preferred?
    
    # Unset other preferred suppliers for this part
    SupplierPart.where(part_id: part_id, preferred: true)
                .where.not(id: id)
                .update_all(preferred: false)
  end
end
