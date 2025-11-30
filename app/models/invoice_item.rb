class InvoiceItem < ApplicationRecord
  belongs_to :invoice
  belongs_to :listing, optional: true
  
  validates :description, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :rate, numericality: { greater_than_or_equal_to: 0 }
  validates :item_type, inclusion: { 
    in: %w[inventory down_payment parts service fee custom],
    allow_nil: true
  }
  
  before_validation :calculate_amount
  
  ITEM_TYPES = {
    'inventory' => 'Inventory/Unit',
    'down_payment' => 'Down Payment',
    'parts' => 'Parts',
    'service' => 'Service',
    'fee' => 'Fee',
    'custom' => 'Custom'
  }.freeze
  
  private
  
  def calculate_amount
    self.amount = (quantity || 1) * (rate || 0)
  end
end
