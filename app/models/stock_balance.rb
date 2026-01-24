# frozen_string_literal: true

class StockBalance < ApplicationRecord
  belongs_to :company
  belongs_to :part
  belongs_to :location
  belongs_to :bin, optional: true
  
  validates :company_id, presence: true
  validates :part_id, presence: true
  validates :location_id, presence: true
  
  before_save :calculate_available
  
  scope :for_company, ->(company_id) { where(company_id: company_id) }
  scope :for_part, ->(part_id) { where(part_id: part_id) }
  scope :for_location, ->(location_id) { where(location_id: location_id) }
  scope :for_bin, ->(bin_id) { where(bin_id: bin_id) }
  scope :with_stock, -> { where('on_hand > 0') }
  scope :low_stock, -> { 
    joins(:part).joins('LEFT JOIN reorder_rules ON reorder_rules.part_id = parts.id AND reorder_rules.location_id = stock_balances.location_id')
      .where('stock_balances.available <= reorder_rules.reorder_point')
  }
  
  def self.update_from_transaction(transaction)
    Rails.logger.info("[StockBalance.update_from_transaction] Starting for transaction #{transaction.id}")
    
    balance = find_or_initialize_by(
      company_id: transaction.company_id,
      part_id: transaction.part_id,
      location_id: transaction.location_id,
      bin_id: transaction.bin_id,
      serial_number: transaction.serial_number,
      lot_number: transaction.lot_number
    )
    
    Rails.logger.info("[StockBalance.update_from_transaction] Balance #{balance.new_record? ? 'new' : 'existing'}, current on_hand: #{balance.on_hand}, reserved: #{balance.reserved}")
    
    # Set defaults for new records
    balance.on_hand ||= 0
    balance.reserved ||= 0
    
    balance.on_hand = balance.on_hand + transaction.quantity
    balance.lot_expiration_date = transaction.lot_expiration_date if transaction.lot_expiration_date.present?
    balance.last_transaction_at = transaction.transaction_date
    
    Rails.logger.info("[StockBalance.update_from_transaction] New on_hand: #{balance.on_hand}, available will be: #{balance.on_hand - balance.reserved}")
    
    balance.save!
    
    Rails.logger.info("[StockBalance.update_from_transaction] Successfully saved")
    balance
  rescue StandardError => e
    Rails.logger.error("[StockBalance.update_from_transaction] ERROR: #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e
  end
  
  def recalculate!
    total = InventoryTransaction.where(
      company_id: company_id,
      part_id: part_id,
      location_id: location_id,
      bin_id: bin_id,
      serial_number: serial_number,
      lot_number: lot_number
    ).sum(:quantity)
    
    update!(on_hand: total)
  end
  
  def reserve!(quantity)
    if quantity > available
      errors.add(:base, "Cannot reserve #{quantity} - only #{available} available")
      raise ActiveRecord::RecordInvalid, self
    end
    
    self.reserved += quantity
    save!
  end
  
  def release!(quantity)
    if quantity > reserved
      errors.add(:base, "Cannot release #{quantity} - only #{reserved} reserved")
      raise ActiveRecord::RecordInvalid, self
    end
    
    self.reserved -= quantity
    save!
  end
  
  def low_stock?
    reorder_rule = ReorderRule.find_by(part_id: part_id, location_id: location_id, active: true)
    return false unless reorder_rule
    
    available <= reorder_rule.reorder_point
  end
  
  def at_maximum?
    reorder_rule = ReorderRule.find_by(part_id: part_id, location_id: location_id, active: true)
    return false unless reorder_rule&.maximum_stock.present?
    
    on_hand >= reorder_rule.maximum_stock
  end
  
  def location_name
    location&.name
  end
  
  def bin_name
    bin&.display_name
  end
  
  def part_sku
    part&.sku
  end
  
  def as_json(options = {})
    super(options.merge(
      only: [:id, :on_hand, :reserved, :available, :serial_number, :lot_number, 
             :lot_expiration_date, :last_transaction_at],
      methods: [:low_stock?, :location_name, :bin_name, :part_sku],
      include: {
        part: { only: [:id, :sku, :name] },
        location: { only: [:id, :name, :code] },
        bin: { only: [:id, :bin_code, :label] }
      }
    ))
  end
  
  private
  
  def calculate_available
    self.on_hand ||= 0
    self.reserved ||= 0
    self.available = on_hand - reserved
  end
end
