# frozen_string_literal: true

class QuoteInventoryUsage < ApplicationRecord
  # Associations
  belongs_to :quote
  belongs_to :part
  belongs_to :location, optional: true
  belongs_to :used_by, class_name: 'User', optional: true
  
  # Validations
  validates :quantity, presence: true, numericality: { greater_than: 0 }
  validates :item_index, presence: true
  
  # Scopes
  scope :used, -> { where(used: true) }
  scope :not_used, -> { where(used: false) }
  scope :for_location, ->(location_id) { where(location_id: location_id) }
  
  # Mark parts as used and update inventory
  def mark_as_used!(user)
    return false if used?
    
    transaction do
      # Update this record
      update!(
        used: true,
        used_at: Time.current,
        used_by: user
      )
      
      # Create inventory transaction (stock balance updated automatically via after_create callback)
      InventoryTransaction.create!(
        company_id: quote.company_id,
        part: part,
        location_id: location_id || part.stock_balances.first&.location_id,
        transaction_type: 'consume',
        quantity: -quantity,
        unit_cost: unit_cost || part.default_cost || 0,
        reference_type: 'Quote',
        reference_id: quote_id,
        created_by_id: user.id,
        transaction_date: Time.current,
        notes: "Used for Quote ##{quote.quote_number}"
      )
      
      # Note: Stock balance is updated automatically by InventoryTransaction's after_create callback
      # No manual stock update needed here
    end
    
    true
  rescue => e
    Rails.logger.error "Failed to mark quote inventory as used: #{e.message}"
    false
  end
  
  # Check if enough stock is available
  def stock_available?
    return false unless part && location_id
    
    stock = part.stock_balances.find_by(location_id: location_id)
    return false unless stock
    
    stock.available >= quantity
  end
  
  # Get current stock level
  def stock_level
    return 0 unless part && location_id
    
    stock = part.stock_balances.find_by(location_id: location_id)
    stock&.available || 0
  end
end
