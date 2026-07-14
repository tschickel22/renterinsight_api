# frozen_string_literal: true

# Payment Model
# 
# Represents a payment transaction, either standalone or associated with a loan.
# Integrates with external payment gateways (Zego, Stripe) and tracks processing fees.

class Payment < ApplicationRecord
  include ActivityTrackable
  include LocationAware
  include Reportable

  def self.reportable_config
    {
      label: "Payments",
      category: "finance",
      fields: [
        { key: "id",             label: "ID",              type: "number",  filterable: true,  sortable: true  },
        { key: "payment_number", label: "Payment Number",  type: "string",  filterable: true,  sortable: true  },
        { key: "payment_type",   label: "Payment Type",   type: "enum",    filterable: true,  sortable: true  },
        { key: "gateway_name",   label: "Gateway",        type: "enum",    filterable: true,  sortable: true  },
        { key: "status",         label: "Status",         type: "enum",    filterable: true,  sortable: true  },
        { key: "amount",         label: "Amount",         type: "number",  filterable: true,  sortable: true  },
        { key: "fee_amount",     label: "Fee Amount",     type: "number",  filterable: true,  sortable: true  },
        { key: "processing_fee", label: "Processing Fee", type: "number",  filterable: true,  sortable: true  },
        { key: "total_charged",  label: "Total Charged",  type: "number",  filterable: true,  sortable: true  },
        { key: "payer_type",     label: "Payer Type",     type: "string",  filterable: true,  sortable: false },
        { key: "payment_date",   label: "Payment Date",   type: "date",    filterable: true,  sortable: true  },
        { key: "processed_at",   label: "Processed At",   type: "date",    filterable: true,  sortable: true  },
        { key: "created_at",     label: "Created At",     type: "date",    filterable: true,  sortable: true  }
      ]
    }
  end
  include WebhookNotifiable
  
  # Constants
  STATUSES = %w[pending processing completed failed refunded cancelled voided].freeze
  PAYMENT_TYPES = %w[loan_payment one_time deposit fee screening_fee application_fee].freeze
  FEE_RESPONSIBILITIES = %w[customer company].freeze
  FEE_TYPES = %w[percentage fixed percentage_plus_fixed].freeze
  GATEWAY_NAMES = %w[zego stripe manual].freeze
  
  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :loan, optional: true
  belongs_to :payment_method, optional: true
  belongs_to :payer, polymorphic: true, optional: true
  # `payable` (polymorphic) is legacy — retained for the loan portal path
  # which still passes it, but new invoice-side flows go through
  # payment_applications and leave these columns nil.
  belongs_to :payable, polymorphic: true, optional: true
  has_many   :payment_applications, dependent: :destroy
  
  # Validations
  validates :company_id, presence: true
  validates :payment_number, presence: true, uniqueness: { scope: :company_id }
  validates :payment_type, presence: true, inclusion: { in: PAYMENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :payment_method_id, presence: true, unless: :manual_payment?
  validates :fee_responsibility, inclusion: { in: FEE_RESPONSIBILITIES }, allow_nil: true
  validates :fee_type, inclusion: { in: FEE_TYPES }, allow_nil: true
  validates :gateway_name, inclusion: { in: GATEWAY_NAMES }, allow_nil: true
  
  # Scopes
  scope :completed, -> { where(status: 'completed') }
  scope :pending, -> { where(status: 'pending') }
  scope :processing, -> { where(status: 'processing') }
  scope :failed, -> { where(status: 'failed') }
  scope :refunded, -> { where(status: 'refunded') }
  scope :for_loan, ->(loan) { where(loan: loan) }
  scope :for_payer, ->(payer) { where(payer: payer) }
  scope :by_type, ->(type) { where(payment_type: type) }
  scope :by_status, ->(status) { where(status: status) }
  scope :by_gateway, ->(gateway) { where(gateway_name: gateway) }
  scope :scheduled, -> { where(status: 'pending').where('scheduled_at IS NOT NULL') }
  scope :due_today, -> { scheduled.where('DATE(scheduled_at) = ?', Date.current) }
  scope :overdue, -> { scheduled.where('scheduled_at < ?', Time.current) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_date, ->(start_date, end_date) { where(payment_date: start_date..end_date) }
  
  # Callbacks
  before_validation :generate_payment_number, on: :create
  before_validation :calculate_total_charged
  before_validation :set_payment_date, if: -> { payment_date.nil? && status == 'completed' }
  before_save :stringify_metadata_keys
  after_initialize :set_defaults, if: :new_record?
  after_commit :update_loan_after_completion, if: -> { saved_change_to_status? && status == 'completed' && !try(:skip_loan_processing?) }
  after_commit :notify_applicables_of_status_change, if: :saved_change_to_status?
  after_commit :fire_lifecycle_webhooks, if: :saved_change_to_status?
  after_commit :auto_post_to_accounting, if: -> { saved_change_to_status? && status == 'completed' }
  after_commit :auto_post_refund_to_accounting, if: -> { saved_change_to_status? && status == 'refunded' }

  def auto_post_to_accounting
    Accounting::PaymentPostingService.new(self).post!
  rescue => e
    Rails.logger.error("[AutoPost] Payment #{id} failed: #{e.message}")
  end

  def auto_post_refund_to_accounting
    Accounting::PaymentPostingService.new(self).post_refund!
  rescue => e
    Rails.logger.error("[AutoPost] Payment refund #{id} failed: #{e.message}")
  end
  
  # Instance methods
  def display_name
    "Payment ##{payment_number}"
  end
  
  def payer_name
    return 'No Payer' if payer.nil?
    
    if payer.respond_to?(:full_name)
      payer.full_name
    elsif payer.respond_to?(:name)
      payer.name
    else
      "Payer ##{payer_id}"
    end
  end
  
  def completed?
    status == 'completed'
  end
  
  def pending?
    status == 'pending'
  end
  
  def failed?
    status == 'failed'
  end
  
  def refunded?
    status == 'refunded'
  end
  
  def processing?
    status == 'processing'
  end
  
  def can_refund?
    completed? && !refunded? && external_id.present?
  end
  
  def can_void?
    (pending? || processing?) && external_id.present?
  end
  
  def total_amount
    total_charged || amount
  end
  
  def customer_pays_fee?
    fee_responsibility == 'customer'
  end
  
  def company_pays_fee?
    fee_responsibility == 'company'
  end
  
  def has_processing_fee?
    processing_fee.to_f > 0
  end
  
  # Mark as completed
  def mark_completed!(external_id: nil, processed_time: Time.current)
    update!(
      status: 'completed',
      processed_at: processed_time,
      payment_date: processed_time.to_date,
      external_id: external_id || self.external_id
    )
  end
  
  # Mark as failed
  def mark_failed!(reason)
    update!(
      status: 'failed',
      failure_reason: reason,
      processed_at: Time.current
    )
  end
  
  # Process refund
  def process_refund!(amount: nil, reason: nil)
    return false unless can_refund?
    
    refund_amt = amount || self.amount
    
    transaction do
      update!(
        status: 'refunded',
        is_refunded: true,
        refund_amount: refund_amt,
        refunded_at: Time.current,
        refund_reason: reason
      )
      
      # If this was a loan payment, reverse the loan state
      if loan.present? && loan.active?
        loan.update!(
          total_paid: [loan.total_paid - principal_amount.to_f, 0].max,
          current_balance: loan.current_balance + principal_amount.to_f,
          payments_made: [loan.payments_made - 1, 0].max
        )
      end
    end
    
    true
  rescue => e
    Rails.logger.error("Error processing refund for payment #{id}: #{e.message}")
    false
  end
  
  # Void payment
  def void!
    return false unless can_void?
    
    update!(status: 'voided')
  end
  
  # Cancel scheduled payment
  def cancel!
    return false unless pending?
    
    update!(status: 'cancelled')
  end
  
  # How much of this payment has been applied to targets (invoices, etc).
  def applied_amount
    payment_applications.sum(:amount)
  end

  # Leftover payment that hasn't been assigned to any invoice — surface this
  # in the UI as unapplied credit.
  def unapplied_amount
    (amount || 0) - applied_amount
  end

  def fully_applied?
    applied_amount >= (amount || 0)
  end

  # Convenience: create an application against a target with an amount that
  # defaults to whatever's still unapplied on the payment.
  def apply_to!(target, amount: nil, applied_at: Time.current, created_by: nil)
    payment_applications.create!(
      company_id: company_id,
      applicable: target,
      amount: amount || unapplied_amount,
      applied_at: applied_at,
      created_by: created_by
    )
  end

  # Payment breakdown for display
  def breakdown
    {
      principal: principal_amount || 0,
      interest: interest_amount || 0,
      fees: fee_amount || 0,
      late_fees: late_fee_amount || 0,
      processing_fee: processing_fee || 0,
      total: total_charged || amount
    }
  end
  
  def fee_description
    return 'No fee' unless has_processing_fee?
    
    case fee_type
    when 'percentage'
      "#{fee_value}%"
    when 'fixed'
      "$#{fee_value}"
    when 'percentage_plus_fixed'
      "#{fee_value}% + fixed"
    else
      'Processing fee'
    end
  end
  
  # Soft delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current)
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  def manual_payment?
    gateway_name == 'manual' || payment_method_id.nil?
  end
  
  private
  
  # Metadata JSONB must be stored with string keys — Invoice#record_payment!
  # and other callers pass symbol keys via Ruby literal hashes, which then
  # break dedup checks and frontend parsing that assumes strings.
  def stringify_metadata_keys
    self.metadata = metadata.deep_stringify_keys if metadata.is_a?(Hash)
  end

  def set_defaults
    self.status ||= 'pending'
    self.payment_type ||= 'one_time'
    self.principal_amount ||= 0
    self.interest_amount ||= 0
    self.fee_amount ||= 0
    self.late_fee_amount ||= 0
    self.processing_fee ||= 0
    self.is_refunded = false if is_refunded.nil?
    self.is_deleted = false if is_deleted.nil?
    self.payment_date ||= Date.current if status == 'completed'
  end
  
  def generate_payment_number
    return if payment_number.present?
    
    timestamp = Time.current.strftime('%Y%m%d')
    random = SecureRandom.hex(3).upcase
    self.payment_number = "PAY-#{timestamp}-#{random}"
  end
  
  def calculate_total_charged
    return if amount.nil?
    
    if customer_pays_fee? && processing_fee.to_f > 0
      self.total_charged = amount + processing_fee
    else
      self.total_charged = amount
    end
  end
  
  def set_payment_date
    self.payment_date = Date.current
  end
  
  def update_loan_after_completion
    return unless loan.present?
    
    loan.process_payment!(self)
  end
  
  # Notify every target this payment applies to that the payment's status
  # changed, so their amount_paid / status recomputes off the current set of
  # applications joined with completed payments.
  def notify_applicables_of_status_change
    payment_applications.includes(:applicable).each do |app|
      next unless app.applicable.respond_to?(:update_status_based_on_payments)
      app.applicable.update_status_based_on_payments
    end
  rescue ActiveRecord::RecordNotFound
    # Applicable was destroyed in the same transaction.
  end

  # Fire custom lifecycle webhook events on status transitions
  # WebhookNotifiable handles generic payment.created/updated/deleted
  # This adds payment.received and payment.refunded for specific transitions.
  def fire_lifecycle_webhooks
    event = case status
            when 'completed' then 'payment.received'
            when 'refunded'  then 'payment.refunded'
            end

    return unless event

    WebhookService.fire(
      company_id: company_id,
      event: event,
      payload: webhook_payload
    )
  rescue => e
    Rails.logger.error "[Payment] Failed to fire lifecycle webhook #{event}: #{e.message}"
  end

  # ActivityTrackable overrides
  def activity_display_name
    try(:description) || "Payment ##{id}"
  end

  def activity_module_name
    'finance'
  end

  def activity_account_id
    if try(:account_id)
      account_id
    elsif respond_to?(:payable) && payable.respond_to?(:account_id)
      payable.try(:account_id)
    elsif respond_to?(:payable) && payable.respond_to?(:contact)
      payable.contact&.try(:account_id)
    else
      nil
    end
  end
end
