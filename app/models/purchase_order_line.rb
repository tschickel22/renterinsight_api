# frozen_string_literal: true

class PurchaseOrderLine < ApplicationRecord
  # Associations
  belongs_to :purchase_order
  belongs_to :part
  has_many :inventory_transactions, dependent: :nullify
  
  # Delegations
  delegate :company, to: :purchase_order
  delegate :supplier, to: :purchase_order
  
  # Validations
  validates :purchase_order_id, presence: true
  validates :part_id, presence: true
  validates :line_number, presence: true, uniqueness: { scope: :purchase_order_id }
  validates :quantity_ordered, presence: true, numericality: { greater_than: 0 }
  validates :quantity_received, numericality: { greater_than_or_equal_to: 0 }
  validates :unit_cost, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validate :quantity_received_cannot_exceed_ordered
  
  # Callbacks
  before_validation :set_line_number, on: :create
  before_save :calculate_line_total
  after_save :update_purchase_order_totals
  after_destroy :update_purchase_order_totals
  
  # Scopes
  scope :ordered, -> { order(:line_number) }
  scope :for_part, ->(part_id) { where(part_id: part_id) }
  scope :fully_received, -> { where('quantity_received >= quantity_ordered') }
  scope :partially_received, -> { where('quantity_received > 0 AND quantity_received < quantity_ordered') }
  scope :not_received, -> { where(quantity_received: 0) }
  
  # Status helpers
  def fully_received?
    quantity_received >= quantity_ordered
  end
  
  def partially_received?
    quantity_received > 0 && !fully_received?
  end
  
  def not_received?
    quantity_received.zero?
  end
  
  def quantity_remaining
    quantity_ordered - quantity_received
  end
  
  def percent_received
    return 0 if quantity_ordered.zero?
    ((quantity_received / quantity_ordered) * 100).round(2)
  end
  
  def can_receive?
    !fully_received? && purchase_order.can_receive?
  end
  
  # Receive inventory against this line
  def receive!(quantity, location_id:, bin_id: nil, user:, notes: nil)
    raise "Cannot receive more than ordered" if (quantity_received + quantity) > quantity_ordered
    raise "Cannot receive against this PO" unless purchase_order.can_receive?
    
    ActiveRecord::Base.transaction do
      # Create inventory transaction
      transaction = InventoryTransaction.create!(
        company: company,
        part: part,
        location_id: location_id,
        bin_id: bin_id,
        transaction_type: 'receive',
        quantity: quantity,
        unit_cost: unit_cost,
        purchase_order_line_id: id,
        notes: notes || "Received against #{purchase_order.po_number} Line #{line_number}",
        transaction_date: Time.current,
        created_by: user
      )
      
      # Update quantity received
      self.quantity_received += quantity
      save!
      
      # Update PO status
      purchase_order.update_status_based_on_lines
      
      transaction
    end
  end
  
  # Display helpers
  def display_name
    "Line #{line_number}: #{part.name}"
  end
  
  def part_sku
    part&.sku
  end
  
  def part_name
    part&.name
  end
  
  def part_uom
    part&.uom
  end
  
  def extended_cost
    line_total
  end
  
  def as_json(options = {})
    super(options.merge(
      only: [:id, :line_number, :quantity_ordered, :quantity_received, :unit_cost, 
             :line_total, :description, :notes, :expected_date, :manufacturer_part_no],
      methods: [:quantity_remaining, :percent_received, :fully_received?, :part_sku, 
                :part_name, :part_uom],
      include: {
        part: { only: [:id, :sku, :name, :uom, :description] }
      }
    ))
  end
  
  private
  
  def set_line_number
    return if line_number.present?
    
    max_line = purchase_order.purchase_order_lines.maximum(:line_number) || 0
    self.line_number = max_line + 1
  end
  
  def calculate_line_total
    self.line_total = (quantity_ordered || 0) * (unit_cost || 0)
  end
  
  def update_purchase_order_totals
    purchase_order.calculate_totals
    purchase_order.save! if purchase_order.changed?
  end
  
  def quantity_received_cannot_exceed_ordered
    if quantity_received.present? && quantity_ordered.present? && quantity_received > quantity_ordered
      errors.add(:quantity_received, "cannot exceed quantity ordered (#{quantity_ordered})")
    end
  end
end
