# frozen_string_literal: true

class InventoryTransactionService
  attr_reader :company, :user, :errors
  
  def initialize(company, user)
    @company = company
    @user = user
    @errors = []
  end
  
  # Receive inventory (from purchase order or manual receive)
  def receive(params)
    @errors = []
    
    ActiveRecord::Base.transaction do
      transaction = company.inventory_transactions.create!(
        part_id: params[:part_id],
        location_id: params[:location_id],
        bin_id: params[:bin_id],
        transaction_type: 'receive',
        quantity: params[:quantity].to_f.abs,
        unit_cost: params[:unit_cost],
        serial_number: params[:serial_number],
        lot_number: params[:lot_number],
        lot_expiration_date: params[:lot_expiration_date],
        purchase_order_line_id: params[:purchase_order_line_id],
        notes: params[:notes],
        transaction_date: params[:transaction_date] || Time.current,
        created_by: user
      )
      
      update_part_costs(transaction)
      
      return transaction
    end
  rescue ActiveRecord::RecordInvalid => e
    @errors = e.record.errors.full_messages
    nil
  rescue StandardError => e
    @errors = [e.message]
    nil
  end
  
  # Transfer inventory between locations
  def transfer(params)
    @errors = []
    
    source_balance = StockBalance.find_by(
      company_id: company.id,
      part_id: params[:part_id],
      location_id: params[:from_location_id],
      bin_id: params[:from_bin_id]
    )
    
    quantity = params[:quantity].to_f.abs
    
    if source_balance.nil? || source_balance.available < quantity
      @errors << "Insufficient stock at source location. Available: #{source_balance&.available || 0}, Requested: #{quantity}"
      return nil
    end
    
    ActiveRecord::Base.transaction do
      transfer_out = company.inventory_transactions.create!(
        part_id: params[:part_id],
        location_id: params[:from_location_id],
        bin_id: params[:from_bin_id],
        transaction_type: 'transfer_out',
        quantity: -quantity,
        unit_cost: source_balance.part.average_cost || source_balance.part.default_cost,
        serial_number: params[:serial_number],
        lot_number: params[:lot_number],
        notes: "Transfer to #{Location.find(params[:to_location_id]).name}#{params[:notes].present? ? " - #{params[:notes]}" : ""}",
        transaction_date: params[:transaction_date] || Time.current,
        created_by: user
      )
      
      transfer_in = company.inventory_transactions.create!(
        part_id: params[:part_id],
        location_id: params[:to_location_id],
        bin_id: params[:to_bin_id],
        transaction_type: 'transfer_in',
        quantity: quantity,
        unit_cost: transfer_out.unit_cost,
        serial_number: params[:serial_number],
        lot_number: params[:lot_number],
        lot_expiration_date: params[:lot_expiration_date],
        source_transaction_id: transfer_out.id,
        notes: "Transfer from #{Location.find(params[:from_location_id]).name}#{params[:notes].present? ? " - #{params[:notes]}" : ""}",
        transaction_date: params[:transaction_date] || Time.current,
        created_by: user
      )
      
      return { transfer_out: transfer_out, transfer_in: transfer_in }
    end
  rescue ActiveRecord::RecordInvalid => e
    @errors = e.record.errors.full_messages
    nil
  rescue StandardError => e
    @errors = [e.message]
    nil
  end
  
  # Adjust inventory
  def adjust(params)
    @errors = []
    
    ActiveRecord::Base.transaction do
      transaction = company.inventory_transactions.create!(
        part_id: params[:part_id],
        location_id: params[:location_id],
        bin_id: params[:bin_id],
        transaction_type: 'adjustment',
        quantity: params[:quantity].to_f,
        unit_cost: params[:unit_cost],
        serial_number: params[:serial_number],
        lot_number: params[:lot_number],
        notes: params[:notes] || 'Inventory adjustment',
        transaction_date: params[:transaction_date] || Time.current,
        created_by: user
      )
      
      return transaction
    end
  rescue ActiveRecord::RecordInvalid => e
    @errors = e.record.errors.full_messages
    nil
  rescue StandardError => e
    @errors = [e.message]
    nil
  end
  
  # Consume inventory
  def consume(params)
    @errors = []
    
    balance = StockBalance.find_by(
      company_id: company.id,
      part_id: params[:part_id],
      location_id: params[:location_id],
      bin_id: params[:bin_id]
    )
    
    quantity = params[:quantity].to_f.abs
    
    if balance.nil? || balance.available < quantity
      @errors << "Insufficient stock. Available: #{balance&.available || 0}, Requested: #{quantity}"
      return nil
    end
    
    ActiveRecord::Base.transaction do
      transaction = company.inventory_transactions.create!(
        part_id: params[:part_id],
        location_id: params[:location_id],
        bin_id: params[:bin_id],
        transaction_type: 'consume',
        quantity: -quantity,
        unit_cost: balance.part.average_cost || balance.part.default_cost,
        job_id: params[:job_id],
        reference_type: params[:reference_type],
        reference_id: params[:reference_id],
        serial_number: params[:serial_number],
        lot_number: params[:lot_number],
        notes: params[:notes],
        transaction_date: params[:transaction_date] || Time.current,
        created_by: user
      )
      
      return transaction
    end
  rescue ActiveRecord::RecordInvalid => e
    @errors = e.record.errors.full_messages
    nil
  rescue StandardError => e
    @errors = [e.message]
    nil
  end
  
  # Return inventory
  def return_inventory(params)
    @errors = []
    
    ActiveRecord::Base.transaction do
      transaction = company.inventory_transactions.create!(
        part_id: params[:part_id],
        location_id: params[:location_id],
        bin_id: params[:bin_id],
        transaction_type: 'return',
        quantity: params[:quantity].to_f.abs,
        unit_cost: params[:unit_cost],
        job_id: params[:job_id],
        reference_type: params[:reference_type],
        reference_id: params[:reference_id],
        serial_number: params[:serial_number],
        lot_number: params[:lot_number],
        notes: params[:notes],
        transaction_date: params[:transaction_date] || Time.current,
        created_by: user
      )
      
      return transaction
    end
  rescue ActiveRecord::RecordInvalid => e
    @errors = e.record.errors.full_messages
    nil
  rescue StandardError => e
    @errors = [e.message]
    nil
  end
  
  def part_history(part_id, location_id: nil, limit: 100)
    query = company.inventory_transactions.where(part_id: part_id)
    query = query.where(location_id: location_id) if location_id.present?
    query.recent.limit(limit)
  end
  
  def stock_at(part_id, location_id, bin_id: nil)
    query = StockBalance.where(
      company_id: company.id,
      part_id: part_id,
      location_id: location_id
    )
    query = query.where(bin_id: bin_id) if bin_id.present?
    query.sum(:available)
  end
  
  private
  
  def update_part_costs(transaction)
    part = transaction.part
    return if transaction.unit_cost.nil?
    
    part.update_column(:last_cost, transaction.unit_cost)
    
    current_on_hand = part.total_on_hand
    current_avg = part.average_cost || transaction.unit_cost
    
    if current_on_hand > 0
      new_avg = ((current_avg * current_on_hand) + (transaction.unit_cost * transaction.quantity)) / 
                (current_on_hand + transaction.quantity)
      part.update_column(:average_cost, new_avg)
    else
      part.update_column(:average_cost, transaction.unit_cost)
    end
  end
end
