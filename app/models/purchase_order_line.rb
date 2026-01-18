# frozen_string_literal: true

class PurchaseOrderLine < ApplicationRecord
  # Associations
  belongs_to :purchase_order
  belongs_to :part
  has_many :inventory_transactions, dependent: :nullify
  
  # Validations
  validates :purchase_order_id, presence: true
  validates :part_id, presence: true
  validates :line_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :quantity_ordered, presence: true, numericality: { greater_than: 0 }
  validates :unit_cost, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :quantity_received, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  
  # Callbacks
  before_save :calculate_line_total
  after_save :update_purchase_order_totals
  after_destroy :update_purchase_order_totals
  
  # Scopes
  scope :for_part, ->(part_id) { where(part_id: part_id) }
  scope :pending, -> { where('quantity_received < quantity_ordered OR quantity_received IS NULL') }
  scope :fully_received, -> { where('quantity_received >= quantity_ordered') }
  
  # Status methods
  def fully_received?
    quantity_received.to_f >= quantity_ordered
  end
  
  def partially_received?
    quantity_received.to_f > 0 && quantity_received.to_f < quantity_ordered
  end
  
  def percent_received
    return 0 if quantity_ordered.zero?
    ((quantity_received.to_f / quantity_ordered) * 100).round(2)
  end
  
  # Display methods
  def status
    if fully_received?
      'received'
    elsif partially_received?
      'partial'
    else
      'pending'
    end
  end
  
  private
  
  def calculate_line_total
    self.line_total = quantity_ordered * unit_cost
  end
  
  def update_purchase_order_totals
    purchase_order.calculate_totals
    purchase_order.save if purchase_order.persisted?
  end
end
