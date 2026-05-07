class Invoice < ApplicationRecord
  include ActivityTrackable
  include Addressable
  include Buyable
  include WebhookNotifiable
  include Reportable

  def self.reportable_config
    {
      label: "Invoices",
      category: "finance",
      fields: [
        { key: "id",              label: "ID",              type: "number",  filterable: true,  sortable: true  },
        { key: "invoice_number",  label: "Invoice Number",  type: "string",  filterable: true,  sortable: true  },
        { key: "status",          label: "Status",          type: "enum",    filterable: true,  sortable: true  },
        { key: "billing_category",label: "Billing Category",type: "enum",    filterable: true,  sortable: true  },
        { key: "subtotal",        label: "Subtotal",        type: "number",  filterable: true,  sortable: true  },
        { key: "tax_amount",      label: "Tax",             type: "number",  filterable: true,  sortable: true  },
        { key: "total",           label: "Total",           type: "number",  filterable: true,  sortable: true  },
        { key: "amount_paid",     label: "Amount Paid",     type: "number",  filterable: true,  sortable: true  },
        { key: "amount_due",      label: "Amount Due",      type: "number",  filterable: true,  sortable: true  },
        { key: "contact_id",      label: "Contact",         type: "number",  filterable: true,  sortable: true  },
        { key: "deal_id",         label: "Deal",            type: "number",  filterable: true,  sortable: true  },
        { key: "invoice_date",    label: "Invoice Date",    type: "date",    filterable: true,  sortable: true  },
        { key: "due_date",        label: "Due Date",        type: "date",    filterable: true,  sortable: true  },
        { key: "sent_at",         label: "Sent At",         type: "date",    filterable: true,  sortable: true  },
        { key: "paid_at",         label: "Paid At",         type: "date",    filterable: true,  sortable: true  },
        { key: "notes",           label: "Notes",           type: "string",  filterable: false, sortable: false },
        { key: "created_at",      label: "Created At",      type: "date",    filterable: true,  sortable: true  }
      ]
    }
  end

  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :contact, optional: true
  belongs_to :listing, optional: true
  belongs_to :deal, optional: true
  belongs_to :loan, optional: true
  belongs_to :quote, optional: true
  belongs_to :source, polymorphic: true, optional: true
  belongs_to :recipient, polymorphic: true, optional: true
  belongs_to :sales_rep, class_name: 'User', optional: true
  
  has_many :invoice_items, dependent: :destroy
  has_many :payments, as: :payable, dependent: :nullify
  has_many :invoice_inventory_usages, dependent: :destroy
  
  accepts_nested_attributes_for :invoice_items, allow_destroy: true
  
  before_validation :generate_invoice_number, on: :create
  before_validation :generate_payment_token, on: :create
  before_validation :generate_public_token, on: :create
  before_validation :set_default_status, on: :create
  before_save :calculate_totals
  after_save :update_status_based_on_payments
  after_update :mark_inventory_as_used_on_payment, if: -> { saved_change_to_status? && status == 'paid' }
  after_commit :fire_lifecycle_webhooks, if: :saved_change_to_status?
  after_commit :auto_post_to_accounting, on: [:create, :update], if: :should_auto_post_to_accounting?

  def should_auto_post_to_accounting?
    return false unless previous_changes.key?('status') || saved_change_to_status?
    %w[finalized sent viewed partial paid overdue].include?(status)
  end

  def auto_post_to_accounting
    Accounting::InvoicePostingService.new(self).post!
  rescue => e
    Rails.logger.error("[AutoPost] Invoice #{id} failed: #{e.message}")
  end
  
  validates :invoice_number, presence: true, uniqueness: { scope: :company_id }
  validates :invoice_date, presence: true
  validates :status, inclusion: { in: %w[draft finalized sent viewed partial paid overdue cancelled] }
  validates :location_id, presence: { message: 'must be assigned — every invoice must have a location' }
  validate :draw_schedule_sub_items_within_parent

  # Sub-items on a draw are dollar amounts that draw down from the parent draw's calculated amount.
  # Sum of sub_items for any single draw must NOT exceed that draw's amount.
  # Section totals (parent draw amounts) remain fixed.
  #
  # EXCEPTION: When addon_mode == 'additional', sub-items are ADDED ON TOP of the
  # home-price draw amount (e.g., Heartland Homes model). No overage check needed.
  def draw_schedule_sub_items_within_parent
    return if draw_schedule.blank?

    # In 'additional' mode, sub-items are extra charges on top of draws — skip validation
    mode = draw_schedule['addon_mode'] || draw_schedule[:addon_mode]
    return if mode == 'additional'

    draws = draw_schedule.is_a?(Hash) ? (draw_schedule['draws'] || draw_schedule[:draws]) : nil
    return if draws.blank?

    draws.each_with_index do |draw, idx|
      sub_items = draw['sub_items'] || draw[:sub_items]
      next if sub_items.blank?

      parent_amount = draw['amount'].to_f
      sub_total = sub_items.sum { |si| (si['amount'] || si[:amount]).to_f }

      if sub_total > parent_amount + 0.001 # tiny float tolerance
        label = draw['description'].presence || "Draw #{idx + 1}"
        errors.add(:draw_schedule, "sub-items for '#{label}' total $#{format('%.2f', sub_total)} which exceeds the draw amount of $#{format('%.2f', parent_amount)}")
      end
    end
  end
  
  scope :for_current_location, -> { 
    Current.location_filtered? ? where(location_id: Current.location_id) : all 
  }
  scope :not_deleted, -> { where(is_deleted: [false, nil]) }
  scope :drafts, -> { where(status: 'draft') }
  scope :sent, -> { where.not(sent_at: nil) }
  scope :unpaid, -> { where.not(status: ['paid', 'cancelled']) }
  scope :overdue, -> { where('due_date < ? AND status NOT IN (?)', Date.today, ['paid', 'cancelled']) }
  scope :customer_invoices, -> { where(billing_category: 'customer') }
  scope :warranty_invoices, -> { where(billing_category: 'warranty') }
  scope :for_service_tickets, -> { where(source_type: 'ServiceTicket') }
  scope :for_warranty_claims, -> { where(source_type: 'WarrantyClaim') }
  
  # Record a manual payment for this invoice
  def record_payment!(amount, payment_type = 'manual', metadata = {})
    # Create payment record linked to this invoice
    payment = company.payments.build(
      payable_type: 'Invoice',      # CRITICAL: Links payment to invoice
      payable_id: id,                # CRITICAL: Invoice ID
      payer_type: 'Contact',
      payer_id: contact_id,
      amount: amount,
      payment_type: 'one_time',      # FIXED: Use valid payment_type instead of 'manual'
      payment_date: Date.current,    # FIXED: Use payment_date (not payment_at)
      status: 'completed',           # Manual payments are immediately completed
      gateway_name: payment_type,    # Keep 'manual' as gateway_name
      location_id: location_id,
      metadata: metadata.merge(recorded_by: Current.user&.id)  # FIXED: Use Current.user&.id instead of Current.user_id
    )
    
    payment.save!
    
    # Trigger status update (which will call mark_inventory_as_used if status becomes 'paid')
    update_status_based_on_payments
    
    true
  rescue => e
    Rails.logger.error "[Invoice] Failed to record payment: #{e.message}"
    false
  end
  
  # Status methods
  def draft?
    status == 'draft'
  end
  
  def sent?
    !sent_at.nil?
  end
  
  def paid?
    status == 'paid'
  end
  
  def overdue?
    due_date && due_date < Date.today && !paid? && status != 'cancelled'
  end
  
  # Alias for API serialization
  def is_overdue
    overdue?
  end
  
  def is_warranty_invoice?
    billing_category == 'warranty'
  end
  
  def is_customer_invoice?
    billing_category == 'customer'
  end
  
  # Payment link
  def payment_url(base_url = nil)
    # Environment-aware base URL
    base_url ||= if Rails.env.production?
      'https://crm.landlordinsight.com'
    elsif Rails.env.staging?
      'https://staging.crm.landlordinsight.com'
    else
      # Local development
      'https://localhost:5173'
    end
    
    "#{base_url}/pay/invoice/#{payment_token}"
  end
  
  # Public view link for portal
  def public_url(base_url = nil)
    return nil unless public_token.present?
    
    # Environment-aware base URL
    base_url ||= if Rails.env.production?
      'https://crm.landlordinsight.com'
    elsif Rails.env.staging?
      'https://staging.crm.landlordinsight.com'
    else
      # Local development
      'https://localhost:5173'
    end
    
    "#{base_url}/invoice/#{public_token}"
  end
  
  # Mark as finalized (real invoice, not yet sent)
  def finalize!
    update(status: 'finalized') if draft?
  end

  def finalized?
    status == 'finalized'
  end

  # Mark as sent
  def mark_as_sent!
    update(status: 'sent', sent_at: Time.current) if draft? || finalized?
  end
  
  # Mark as viewed
  def mark_as_viewed!
    update(viewed_at: Time.current, status: 'viewed') if status == 'sent'
  end
  
  # REMOVED: Old broken record_payment! method - replaced with new version at line 44 that properly sets payable_type/payable_id
  
  # Auto-deduct inventory when invoice is marked as paid
  def mark_inventory_as_used!(user)
    return unless status == 'paid' # Only process paid invoices
    
    Rails.logger.info "🏭 [Invoice] Starting inventory deduction for Invoice ##{id} (#{invoice_number})"
    inventory_items_count = 0
    deducted_items_count = 0
    
    invoice_items.where(itemable_type: ['Part', 'Vehicle', 'LandParcel']).find_each do |item|
      inventory_items_count += 1
      
      if item.itemable.nil?
        Rails.logger.warn "⚠️ [Invoice] Invoice item ##{item.id} has no itemable (deleted?) - skipping"
        next
      end
      
      # Check if already marked as used
      usage = invoice_inventory_usages.find_or_initialize_by(
        company: company,
        invoice_item: item,
        itemable: item.itemable
      )
      
      if usage.marked?
        Rails.logger.info "ℹ️ [Invoice] Invoice item ##{item.id} already marked as used - skipping"
        next
      end
      
      usage.quantity_used = item.quantity || 1
      usage.save!
      
      begin
        usage.mark_as_used!(user)
        deducted_items_count += 1
        Rails.logger.info "✅ [Invoice] Successfully deducted #{item.quantity} of #{item.itemable_type} ##{item.itemable_id}"
      rescue => e
        Rails.logger.error "❌ [Invoice] Failed to deduct item ##{item.id}: #{e.message}"
        # Continue even if one item fails
      end
    end
    
    Rails.logger.info "🏭 [Invoice] Inventory deduction complete: #{deducted_items_count}/#{inventory_items_count} items processed"
  end
  
  # Manual override to mark inventory as used
  def force_mark_inventory_as_used!(user)
    mark_inventory_as_used!(user)
  end
  
  private
  
  def generate_invoice_number
    return if invoice_number.present?
    
    # Use simple default prefix - can be customized later via company settings
    prefix = 'INV'
    last_invoice = company.invoices.order(created_at: :desc).first
    
    if last_invoice&.invoice_number&.start_with?(prefix)
      last_number = last_invoice.invoice_number.gsub(/\D/, '').to_i
      next_number = last_number + 1
    else
      next_number = 1000
    end
    
    # Handle collisions - keep incrementing until we find an unused number
    loop do
      candidate = "#{prefix}-#{next_number.to_s.rjust(6, '0')}"
      break self.invoice_number = candidate unless company.invoices.exists?(invoice_number: candidate)
      next_number += 1
    end
  end
  
  def generate_payment_token
    self.payment_token ||= SecureRandom.urlsafe_base64(32)
  end
  
  def generate_public_token
    self.public_token ||= SecureRandom.urlsafe_base64(32)
  end
  
  def set_default_status
    self.status ||= 'draft'
  end
  
  def calculate_totals
    self.subtotal = invoice_items.sum(&:amount)
    
    # Per-item tax: if any items have taxable flag set, use per-item calculation
    # Otherwise fall back to invoice-level tax_rate on full subtotal (legacy behavior)
    has_per_item_tax = invoice_items.any? { |item| item.taxable? }
    
    if has_per_item_tax
      # Sum tax only on taxable items, each using its own tax_rate (or invoice default)
      self.tax_amount = invoice_items.sum { |item| item.tax_amount }.round(2)
    else
      # Legacy: apply invoice-level tax_rate to entire subtotal
      self.tax_amount = (subtotal * (tax_rate || 0) / 100).round(2)
    end
    
    self.total = subtotal + tax_amount
    self.amount_due = total - (amount_paid || 0)
  end
  
  def update_status_based_on_payments
    return if is_deleted? || status == 'cancelled'
    
    total_paid = payments.where(status: 'completed').sum(:amount)
    calculated_amount_due = total - total_paid
    
    # Determine new status
    new_status = if total_paid >= total && total > 0
      'paid'
    elsif total_paid > 0 && total_paid < total
      'partial'
    elsif overdue?
      'overdue'
    else
      status # Keep current status if no payment logic applies
    end
    
    # Only update if status would change (to avoid infinite loops)
    if new_status != status
      # Use update! instead of update_columns to trigger callbacks
      # This will trigger mark_inventory_as_used_on_payment when status becomes 'paid'
      update!(
        status: new_status,
        paid_at: (new_status == 'paid' ? (paid_at || Time.current) : paid_at),
        amount_paid: total_paid,
        amount_due: new_status == 'paid' ? 0 : calculated_amount_due
      )
    else
      # Just update amounts without changing status
      update_columns(
        amount_paid: total_paid,
        amount_due: calculated_amount_due
      )
    end
  end
  
  def mark_inventory_as_used_on_payment
    # Find the user who recorded the payment
    last_payment = payments.where(status: 'completed').order(created_at: :desc).first
    
    # Try to get user from metadata first (manual payments store this)
    user_id = last_payment&.metadata&.dig('recorded_by') if last_payment&.metadata.is_a?(Hash)
    user = User.find_by(id: user_id) if user_id
    
    # Fallback to current user or first user as system user
    user ||= Current.user if defined?(Current.user)
    user ||= User.first # Fallback to any user
    
    Rails.logger.info "[Invoice] Invoice #{id} marked as paid, deducting inventory (user: #{user&.id || 'nil'})"
    mark_inventory_as_used!(user) if user
  end

  # Fire custom lifecycle webhook events on status transitions
  # WebhookNotifiable handles generic invoice.created/updated/deleted
  # This adds invoice.paid and invoice.overdue for specific transitions.
  def fire_lifecycle_webhooks
    event = case status
            when 'paid'    then 'invoice.paid'
            when 'overdue' then 'invoice.overdue'
            end

    return unless event

    WebhookService.fire(
      company_id: company_id,
      event: event,
      payload: webhook_payload
    )
  rescue => e
    Rails.logger.error "[Invoice] Failed to fire lifecycle webhook #{event}: #{e.message}"
  end

  # ActivityTrackable overrides
  def activity_display_name
    try(:invoice_number) || "Invoice ##{id}"
  end

  def activity_module_name
    'finance'
  end

  def activity_account_id
    contact&.try(:account_id) || deal&.try(:account_id)
  end
end
