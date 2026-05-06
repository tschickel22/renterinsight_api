# frozen_string_literal: true

class BankAccount < ApplicationRecord
  # Associations
  belongs_to :company
  belongs_to :location
  belongs_to :chart_of_account, optional: true

  has_many :bank_transactions, dependent: :destroy
  has_many :bank_reconciliations, dependent: :destroy
  has_many :bank_rules, dependent: :destroy
  
  # Constants
  ACCOUNT_PURPOSE_OPERATING = 'operating'
  ACCOUNT_PURPOSE_DEPOSIT = 'deposit'
  ACCOUNT_PURPOSES = [ACCOUNT_PURPOSE_OPERATING, ACCOUNT_PURPOSE_DEPOSIT].freeze
  
  ACCOUNT_TYPES = %w[checking savings].freeze
  
  # Validations
  validates :company, presence: true
  validates :location, presence: true
  validates :account_type, presence: true, inclusion: { in: ACCOUNT_TYPES }
  validates :routing_number, presence: true, length: { is: 9 }
  validates :account_number, presence: true
  validates :bank_name, presence: true
  
  # Make account_purpose optional with default
  validates :account_purpose, inclusion: { in: ACCOUNT_PURPOSES }, allow_nil: true
  before_validation :set_default_account_purpose
  
  # Only one account per purpose per location (unless deleted) - only if purpose is set
  validates :account_purpose, 
    uniqueness: { 
      scope: [:location_id, :is_deleted],
      conditions: -> { where(is_deleted: [false, nil]) },
      message: "already exists for this location"
    },
    if: -> { account_purpose.present? }
  
  validates :display_last_four, length: { is: 4 }, allow_blank: true
  
  # Callbacks
  before_validation :normalize_account_numbers
  after_create :set_display_last_four
  
  # Scopes
  scope :active, -> { where(is_active: true, is_deleted: [false, nil]) }
  scope :verified, -> { where(is_verified: true) }
  scope :operating, -> { where(account_purpose: ACCOUNT_PURPOSE_OPERATING) }
  scope :deposit, -> { where(account_purpose: ACCOUNT_PURPOSE_DEPOSIT) }
  scope :for_location, ->(location_id) { where(location_id: location_id) }
  scope :synced_to_zego, -> { where.not(external_id: nil) }
  scope :with_active_feed, -> { where(stripe_fc_status: 'active') }

  # Instance Methods

  def feed_connected?
    stripe_fc_status == 'active'
  end

  def needs_reauth?
    stripe_fc_status.in?(['disconnected', 'requires_reauth'])
  end

  def unconfirmed_transaction_count
    bank_transactions.unmatched.count
  end

  def last_reconciliation
    bank_reconciliations.completed.order(statement_date: :desc).first
  end

  def last_reconciled_balance
    last_reconciliation&.statement_ending_balance
  end
  
  # Display name for UI
  def display_name
    "#{account_purpose.titleize} - #{bank_name} (...#{display_last_four || last_four})"
  end
  
  # Masked account number for display
  def masked_account_number
    return nil unless account_number.present?
    "****#{display_last_four || last_four}"
  end
  
  # Masked routing number for display
  def masked_routing_number
    return nil unless routing_number.present?
    "****#{routing_number[-4..-1]}"
  end
  
  # Last 4 digits of account number
  def last_four
    account_number.present? ? account_number[-4..-1] : nil
  end
  
  # Check if synced to Zego
  def synced_to_zego?
    external_id.present? && is_verified
  end
  
  # Check if locked (synced and cannot be edited)
  def locked?
    locked_at.present?
  end
  
  # Soft delete
  def soft_delete!
    update!(
      is_deleted: true,
      deleted_at: Time.current,
      is_active: false
    )
  end
  
  # Restore from soft delete
  def restore!
    update!(
      is_deleted: false,
      deleted_at: nil,
      is_active: true
    )
  end
  
  # Update display fields only (after Zego has been updated externally)
  # Location Admin and above can do this
  def update_display_info!(last_four:, notes: nil)
    raise "Account must be synced to Zego before updating display" unless synced_to_zego?
    
    update!(
      display_last_four: last_four,
      admin_notes: notes
    )
  end
  
  # Fields that can be updated after Zego sync (display only)
  def editable_display_fields
    %w[display_last_four admin_notes]
  end
  
  # Fields that cannot be changed after Zego sync
  def locked_fields
    %w[routing_number account_number account_type bank_name]
  end
  
  private
  
  def set_default_account_purpose
    # Default to 'operating' if not specified
    self.account_purpose ||= ACCOUNT_PURPOSE_OPERATING
  end
  
  def normalize_account_numbers
    # Strip non-digits from routing and account numbers
    self.routing_number = routing_number.to_s.gsub(/\D/, '') if routing_number.present?
    self.account_number = account_number.to_s.gsub(/\D/, '') if account_number.present?
  end
  
  def set_display_last_four
    # Auto-set display_last_four from account_number on create
    if display_last_four.blank? && account_number.present?
      update_column(:display_last_four, last_four)
    end
  end
end
