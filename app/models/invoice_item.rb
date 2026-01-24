class InvoiceItem < ApplicationRecord
  belongs_to :invoice
  belongs_to :listing, optional: true
  belongs_to :itemable, polymorphic: true, optional: true
  
  validates :description, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :rate, numericality: { greater_than_or_equal_to: 0 }
  validates :item_type, inclusion: { 
    in: %w[inventory down_payment parts service fee custom part labor],
    allow_nil: true
  }
  validates :commission_type, inclusion: {
    in: %w[full_commission parts_only labor_only no_commission],
    allow_nil: true
  }
  
  before_validation :calculate_amount
  before_validation :set_default_commission_type, on: :create
  
  ITEM_TYPES = {
    'inventory' => 'Inventory/Unit',
    'down_payment' => 'Down Payment',
    'parts' => 'Parts',
    'service' => 'Service',
    'fee' => 'Fee',
    'custom' => 'Custom',
    'part' => 'Part',
    'labor' => 'Labor'
  }.freeze
  
  COMMISSION_TYPES = {
    'full_commission' => 'Full Commission (Parts + Labor)',
    'parts_only' => 'Parts Only',
    'labor_only' => 'Labor Only',
    'no_commission' => 'No Commission'
  }.freeze
  
  # Check if this item should earn commission
  def earns_commission?
    commission_type.present? && commission_type != 'no_commission'
  end
  
  # Check if this is a parts/inventory item
  def is_inventory_item?
    itemable_type.present? && ['Part', 'Vehicle', 'LandParcel'].include?(itemable_type)
  end
  
  private
  
  def calculate_amount
    self.amount = (quantity || 1) * (rate || 0)
  end
  
  def set_default_commission_type
    self.commission_type ||= 'full_commission'
  end
end
