class Invoice < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :contact, optional: true
  belongs_to :listing, optional: true
  belongs_to :deal, optional: true
  belongs_to :source, polymorphic: true, optional: true
  belongs_to :recipient, polymorphic: true, optional: true
  
  has_many :invoice_items, dependent: :destroy
  has_many :payments, as: :payable, dependent: :nullify
  
  accepts_nested_attributes_for :invoice_items, allow_destroy: true
  
  before_validation :generate_invoice_number, on: :create
  before_validation :generate_payment_token, on: :create
  before_validation :set_default_status, on: :create
  before_save :calculate_totals
  after_save :update_status_based_on_payments
  
  validates :invoice_number, presence: true, uniqueness: { scope: :company_id }
  validates :invoice_date, presence: true
  validates :status, inclusion: { in: %w[draft sent viewed partial paid overdue cancelled] }
  
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
  
  # Mark as sent
  def mark_as_sent!
    update(status: 'sent', sent_at: Time.current) if draft?
  end
  
  # Mark as viewed
  def mark_as_viewed!
    update(viewed_at: Time.current, status: 'viewed') if status == 'sent'
  end
  
  # Record payment
  def record_payment!(amount, gateway_name, payment_data = {})
    Payment.create!(
      company: company,
      location: location,
      payer_type: contact_id.present? ? 'Contact' : nil,
      payer_id: contact_id,
      payable: self,
      amount: amount,
      gateway_name: gateway_name,
      payment_type: 'one_time',
      status: 'completed',
      payment_date: Time.current,
      external_id: payment_data[:transaction_id],
      notes: payment_data[:notes]
    )
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
  
  def set_default_status
    self.status ||= 'draft'
  end
  
  def calculate_totals
    self.subtotal = invoice_items.sum(&:amount)
    self.tax_amount = (subtotal * (tax_rate || 0) / 100).round(2)
    self.total = subtotal + tax_amount
    self.amount_due = total - (amount_paid || 0)
  end
  
  def update_status_based_on_payments
    return if is_deleted? || status == 'cancelled'
    
    total_paid = payments.where(status: 'completed').sum(:amount)
    calculated_amount_due = total - total_paid
    
    if total_paid >= total && total > 0
      update_columns(
        status: 'paid',
        paid_at: (paid_at || Time.current),
        amount_paid: total_paid,
        amount_due: 0
      )
    elsif total_paid > 0 && total_paid < total
      update_columns(
        status: 'partial',
        amount_paid: total_paid,
        amount_due: calculated_amount_due
      )
    elsif overdue?
      update_columns(
        status: 'overdue',
        amount_paid: total_paid,
        amount_due: calculated_amount_due
      )
    else
      # For other statuses, just update the amounts
      update_columns(
        amount_paid: total_paid,
        amount_due: calculated_amount_due
      )
    end
  end
end
