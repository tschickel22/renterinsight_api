# frozen_string_literal: true

class ReorderRule < ApplicationRecord
  belongs_to :company
  belongs_to :part
  belongs_to :location
  
  validates :company_id, presence: true
  validates :part_id, presence: true
  validates :location_id, presence: true
  validates :reorder_point, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :reorder_quantity, numericality: { greater_than: 0, allow_nil: true }
  validates :maximum_stock, numericality: { greater_than: 0, allow_nil: true }
  validates :part_id, uniqueness: { scope: [:company_id, :location_id] }
  
  validate :maximum_greater_than_reorder_point
  
  scope :active, -> { where(active: true) }
  scope :for_company, ->(company_id) { where(company_id: company_id) }
  scope :for_location, ->(location_id) { where(location_id: location_id) }
  scope :for_part, ->(part_id) { where(part_id: part_id) }
  
  def needs_reorder?
    stock_balance = StockBalance.find_by(
      part_id: part_id,
      location_id: location_id
    )
    
    return false unless stock_balance
    
    stock_balance.available <= reorder_point
  end
  
  def current_stock
    StockBalance.where(part_id: part_id, location_id: location_id).sum(:available)
  end
  
  def suggested_order_quantity
    return reorder_quantity if reorder_quantity.present?
    
    if maximum_stock.present?
      [maximum_stock - current_stock, 0].max
    else
      reorder_point * 2
    end
  end
  
  def as_json(options = {})
    super(options.merge(
      only: [:id, :reorder_point, :reorder_quantity, :maximum_stock, :active],
      methods: [:needs_reorder?, :current_stock, :suggested_order_quantity],
      include: {
        part: { only: [:id, :sku, :name] },
        location: { only: [:id, :name, :code] }
      }
    ))
  end
  
  private
  
  def maximum_greater_than_reorder_point
    return if maximum_stock.nil?
    
    if maximum_stock <= reorder_point
      errors.add(:maximum_stock, "must be greater than reorder point")
    end
  end
end
