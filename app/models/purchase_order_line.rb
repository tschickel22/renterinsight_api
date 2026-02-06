# frozen_string_literal: true

class PurchaseOrderLine < ApplicationRecord
  # Associations
  belongs_to :purchase_order, inverse_of: :lines
  belongs_to :part
  has_many :inventory_transactions, dependent: :nullify
  
  # Delegate part attributes for easier access
  # Creates methods: part_name, part_number (maps to part.sku)
  delegate :name, to: :part, prefix: 'part', allow_nil: true
  delegate :sku, to: :part, prefix: false, allow_nil: true
  
  # Alias sku as part_number for frontend compatibility
  alias_method :part_number, :sku
  
  # Validations
  validates :purchase_order, presence: true
  validates :part, presence: true
  validates :line_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :quantity_ordered, presence: true, numericality: { greater_than: 0 }
  validates :unit_cost, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :discount_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :quantity_received, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  
  # Callbacks
  before_save :calculate_line_total
  after_save :update_purchase_order_totals, unless: :only_quantity_received_changed?
  after_save :update_purchase_order_status, if: :saved_change_to_quantity_received?
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
  
  def only_quantity_received_changed?
    saved_changes.keys == ['quantity_received'] || saved_changes.keys == ['quantity_received', 'updated_at']
  end
  
  def calculate_line_total
    subtotal = quantity_ordered * unit_cost
    discount = subtotal * ((discount_percent || 0) / 100.0)
    self.line_total = subtotal - discount
  end
  
  def update_purchase_order_totals
    # Just trigger a save - the before_save callback will recalculate totals
    purchase_order.save(validate: false) if purchase_order.persisted?
  end
  
  def update_purchase_order_status
    po = purchase_order
    return if po.blank?
    return if po.status == 'cancelled'
    
    # Get all active lines for this PO
    all_lines = po.lines
    
    # Check if all lines are fully received
    fully_received = all_lines.all? { |line| 
      (line.quantity_received || 0) >= line.quantity_ordered 
    }
    
    # Check if any lines have been partially received
    partially_received = all_lines.any? { |line| 
      (line.quantity_received || 0) > 0 
    }
    
    # Determine new status
    new_status = if fully_received
      'received'
    elsif partially_received
      'partially_received'
    else
      po.status # Keep current status if no receipts
    end
    
    # Only update if status has changed
    if po.status != new_status
      updates = { status: new_status }
      
      # Set received_date when fully received for the first time
      if new_status == 'received' && po.received_date.nil?
        updates[:received_date] = Time.current
      end
      
      po.update_columns(updates)
      
      Rails.logger.info "[PO Status] PO ##{po.po_number}: #{po.status} → #{new_status}"
    end
  rescue StandardError => e
    Rails.logger.error "[PO Status Update] Failed: #{e.message}"
    # Don't fail the save if status update fails
  end
end
