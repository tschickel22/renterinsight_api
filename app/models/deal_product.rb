class DealProduct < ApplicationRecord
  belongs_to :deal
  belongs_to :product, optional: true
  
  validates :product_name, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :unit_price, numericality: true  # Allow negative values for discounts/credits
  validates :discount_type, inclusion: { in: %w[fixed percentage], message: "%{value} is not a valid discount type" }, allow_nil: false
  
  before_save :calculate_total
  after_save :update_deal_value
  after_destroy :update_deal_value
  
  private
  
  def calculate_total
    # Calculate subtotal
    subtotal = quantity * unit_price
    
    # Apply discount based on type
    discount_amount = if discount_type == 'percentage'
      subtotal * (discount / 100.0)
    else
      discount
    end
    
    # Calculate final total
    self.total = subtotal - discount_amount + tax
  end
  
  def update_deal_value
    deal.update(value: deal.deal_products.sum(:total))
  end
end
