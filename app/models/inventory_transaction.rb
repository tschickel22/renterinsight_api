# frozen_string_literal: true

class InventoryTransaction < ApplicationRecord
  belongs_to :company
  belongs_to :part
  belongs_to :location
  belongs_to :bin, optional: true
  belongs_to :source_transaction, class_name: 'InventoryTransaction', optional: true
  belongs_to :purchase_order_line, optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  
  TYPES = %w[receive transfer_in transfer_out adjustment consume return sale waste].freeze
  
  validates :company_id, presence: true
  validates :part_id, presence: true
  validates :location_id, presence: true
  validates :transaction_type, presence: true, inclusion: { in: TYPES }
  validates :quantity, presence: true, numericality: { other_than: 0 }
  validates :transaction_date, presence: true
  validates :transaction_number, uniqueness: true, allow_nil: true
  
  before_validation :set_defaults, on: :create
  before_create :generate_transaction_number
  after_create :update_stock_balance
  
  scope :for_company, ->(company_id) { where(company_id: company_id) }
  scope :for_part, ->(part_id) { where(part_id: part_id) }
  scope :for_location, ->(location_id) { where(location_id: location_id) }
  scope :for_bin, ->(bin_id) { where(bin_id: bin_id) }
  scope :by_type, ->(type) { where(transaction_type: type) }
  scope :inbound, -> { where(transaction_type: %w[receive transfer_in return adjustment]).where('quantity > 0') }
  scope :outbound, -> { where(transaction_type: %w[transfer_out consume sale waste adjustment]).where('quantity < 0') }
  scope :recent, -> { order(transaction_date: :desc, created_at: :desc) }
  scope :by_date, -> { order(:transaction_date, :created_at) }
  
  before_update :prevent_changes
  before_destroy :prevent_changes
  
  def display_type
    transaction_type.titleize
  end
  
  def is_inbound?
    quantity > 0
  end
  
  def is_outbound?
    quantity < 0
  end
  
  def abs_quantity
    quantity.abs
  end
  
  def total_value
    return 0 if unit_cost.nil?
    abs_quantity * unit_cost
  end
  
  def is_transfer?
    %w[transfer_in transfer_out].include?(transaction_type)
  end
  
  def transfer_pair
    return nil unless is_transfer?
    
    if transaction_type == 'transfer_out'
      InventoryTransaction.find_by(source_transaction_id: id)
    elsif transaction_type == 'transfer_in' && source_transaction_id.present?
      source_transaction
    end
  end
  
  def as_json(options = {})
    super(options.merge(
      only: [:id, :transaction_type, :quantity, :unit_cost, :transaction_date, 
             :serial_number, :lot_number, :notes, :transaction_number, :created_at],
      methods: [:display_type, :total_value],
      include: {
        part: { only: [:id, :sku, :name] },
        location: { only: [:id, :name, :code] },
        bin: { only: [:id, :bin_code, :label] },
        created_by: { only: [:id, :first_name, :last_name] }
      }
    ))
  end
  
  private
  
  def set_defaults
    self.transaction_date ||= Time.current
  end
  
  def generate_transaction_number
    return if transaction_number.present?
    
    # Find the highest transaction number by extracting numeric part
    last_txn = company.inventory_transactions
                      .where("transaction_number IS NOT NULL")
                      .order(Arel.sql("CAST(SUBSTRING(transaction_number FROM '[0-9]+') AS INTEGER) DESC"))
                      .first
    
    Rails.logger.info("[generate_transaction_number] last_txn: #{last_txn.inspect}")
    Rails.logger.info("[generate_transaction_number] last_txn.transaction_number: #{last_txn&.transaction_number.inspect}")
    
    if last_txn&.transaction_number.present?
      last_num = last_txn.transaction_number.split('-').last.to_i
      new_num = last_num + 1
      self.transaction_number = "TXN-#{new_num.to_s.rjust(5, '0')}"
      Rails.logger.info("[generate_transaction_number] Generated: #{self.transaction_number} (from #{last_txn.transaction_number})")
    else
      self.transaction_number = "TXN-00001"
      Rails.logger.info("[generate_transaction_number] No previous transactions, using TXN-00001")
    end
  end
  
  def update_stock_balance
    StockBalance.update_from_transaction(self)
  rescue StandardError => e
    Rails.logger.error("[InventoryTransaction#update_stock_balance] Failed for transaction #{id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e  # Re-raise to trigger rollback
  end
  
  def prevent_changes
    errors.add(:base, "Inventory transactions are immutable and cannot be changed")
    throw(:abort)
  end
end
