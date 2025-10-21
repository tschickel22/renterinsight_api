class DealProduct < ApplicationRecord
  belongs_to :deal
  belongs_to :product, optional: true
  
  validates :product_name, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :unit_price, numericality: { greater_than_or_equal_to: 0 }
  
  before_save :calculate_total
  after_save :update_deal_value
  after_destroy :update_deal_value
  
  private
  
  def calculate_total
    subtotal = (quantity * unit_price) - discount
    self.total = subtotal + tax
  end
  
  def update_deal_value
    deal.update(value: deal.deal_products.sum(:total))
  end
end
