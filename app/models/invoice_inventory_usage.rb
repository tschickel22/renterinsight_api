class InvoiceInventoryUsage < ApplicationRecord
  belongs_to :company
  belongs_to :invoice
  belongs_to :invoice_item
  belongs_to :itemable, polymorphic: true
  belongs_to :marked_by, class_name: 'User', optional: true
  
  validates :quantity_used, presence: true, numericality: { greater_than: 0 }
  
  # Check if this usage has been marked (inventory deducted)
  def marked?
    marked == true
  end
  
  # Mark this usage as processed and deduct from inventory
  def mark_as_used!(user)
    return if marked? # Already processed
    
    ActiveRecord::Base.transaction do
      # Deduct from inventory based on itemable type
      case itemable_type
      when 'Part'
        deduct_part_inventory!
      when 'Vehicle'
        deduct_vehicle_inventory!
      when 'LandParcel'
        deduct_land_parcel_inventory!
      end
      
      # Mark as used
      update!(
        marked: true,
        marked_at: Time.current,
        marked_by: user
      )
      
      Rails.logger.info "[InvoiceInventoryUsage] Marked usage #{id} - deducted #{quantity_used} of #{itemable_type} ##{itemable_id}"
    end
  rescue => e
    Rails.logger.error "[InvoiceInventoryUsage] Failed to mark usage #{id}: #{e.message}"
    raise
  end
  
  private
  
  def deduct_part_inventory!
    part = itemable
    invoice = invoice_item.invoice
    return unless part

    # Determine location - use invoice location or part's primary stock location
    location_id = invoice.location_id || part.stock_balances.order(available: :desc).first&.location_id
    
    unless location_id
      Rails.logger.warn "[InvoiceInventoryUsage] No location found for Part #{part.id} - cannot deduct inventory"
      return
    end

    # Find stock balance for this location
    stock_balance = part.stock_balances.find_by(
      location_id: location_id,
      bin_id: nil,  # Use default bin for now
      serial_number: nil,
      lot_number: nil
    )

    if stock_balance.nil? || stock_balance.available < quantity_used
      Rails.logger.warn "[InvoiceInventoryUsage] Insufficient stock for Part #{part.id} at Location #{location_id} - requested #{quantity_used}, available #{stock_balance&.available || 0}"
      # Still allow - just log warning
    end

    # Create inventory transaction (negative quantity = reduction)
    transaction = part.inventory_transactions.create!(
      company: company,
      location_id: location_id,
      bin_id: nil,
      transaction_type: 'sale',
      quantity: -quantity_used,  # NEGATIVE for sale
      unit_cost: part.current_cost,
      transaction_date: invoice.paid_at || Time.current,
      notes: "Invoice #{invoice.invoice_number} payment",
      created_by: marked_by
    )

    Rails.logger.info "[InvoiceInventoryUsage] Created sale transaction #{transaction.transaction_number} - deducted #{quantity_used} from Part #{part.id} (#{part.name})"
  rescue => e
    Rails.logger.error "[InvoiceInventoryUsage] Failed to deduct inventory: #{e.message}"
    raise
  end
  
  def deduct_vehicle_inventory!
    vehicle = itemable
    return unless vehicle
    
    # Vehicles are typically one-off items, mark as sold
    if vehicle.respond_to?(:status=)
      vehicle.update!(status: 'sold')
      Rails.logger.info "[InvoiceInventoryUsage] Marked Vehicle #{vehicle.id} as sold"
    end
  end
  
  def deduct_land_parcel_inventory!
    land_parcel = itemable
    return unless land_parcel
    
    # Land parcels are typically one-off items, mark as sold
    if land_parcel.respond_to?(:status=)
      land_parcel.update!(status: 'sold')
      Rails.logger.info "[InvoiceInventoryUsage] Marked LandParcel #{land_parcel.id} as sold"
    end
  end
end
