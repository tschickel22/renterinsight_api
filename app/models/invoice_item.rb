class InvoiceItem < ApplicationRecord
  belongs_to :invoice
  belongs_to :listing, optional: true
  belongs_to :itemable, polymorphic: true, optional: true
  has_many   :invoice_item_taxes, dependent: :destroy
  has_many   :tax_codes, through: :invoice_item_taxes

  validates :description, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :rate, numericality: { greater_than_or_equal_to: 0 }
  validates :item_type, inclusion: { 
    in: %w[inventory down_payment parts service fee custom part labor],
    allow_nil: true
  }
  validates :commission_type, inclusion: {
    in: %w[full_commission parts_only labor_only no_commission],
    allow_nil: true
  }
  validates :category, inclusion: {
    in: %w[home land package basement service fee accessory product other custom],
    allow_nil: true,
    allow_blank: true
  }
  
  before_validation :calculate_amount
  before_validation :set_default_commission_type, on: :create
  
  ITEM_TYPES = {
    'inventory' => 'Inventory/Unit',
    'down_payment' => 'Down Payment',
    'parts' => 'Parts',
    'service' => 'Service',
    'fee' => 'Fee',
    'custom' => 'Custom',
    'part' => 'Part',
    'labor' => 'Labor'
  }.freeze
  
  CATEGORIES = {
    'home' => 'Home/Unit',
    'land' => 'Land',
    'package' => 'Package/Add-On',
    'basement' => 'Basement/Foundation',
    'service' => 'Service',
    'fee' => 'Fee',
    'accessory' => 'Accessory',
    'product' => 'Product',
    'other' => 'Other',
    'custom' => 'Custom'
  }.freeze
  
  COMMISSION_TYPES = {
    'full_commission' => 'Full Commission (Parts + Labor)',
    'parts_only' => 'Parts Only',
    'labor_only' => 'Labor Only',
    'no_commission' => 'No Commission'
  }.freeze
  
  # Check if this item should earn commission
  def earns_commission?
    commission_type.present? && commission_type != 'no_commission'
  end
  
  # Check if this is a parts/inventory item
  def is_inventory_item?
    itemable_type.present? && ['Part', 'Vehicle', 'LandParcel'].include?(itemable_type)
  end

  # Per-item tax amount. Prefers the TaxCode-driven snapshots (sum of
  # invoice_item_taxes.computed_amount). Falls back to the legacy tax_rate
  # calculation so existing invoices from before tax_codes still balance.
  def tax_amount
    return BigDecimal('0') unless taxable? && !skip_tax?

    snapshot_total = invoice_item_taxes.sum(:computed_amount)
    return snapshot_total.round(2) if snapshot_total > 0

    effective_rate = (tax_rate.present? && tax_rate > 0) ? tax_rate : (invoice&.tax_rate || 0)
    ((amount || 0) * effective_rate / 100).round(2)
  end

  # Rebuild invoice_item_taxes from the invoice's company's active TaxCodes.
  # Compound codes tax the running total (subtotal + earlier taxes) in
  # position order; non-compound codes tax the raw subtotal. Tax-exempt
  # contacts and per-line skip_tax overrides zero everything out for the line.
  def recompute_taxes!
    invoice_item_taxes.destroy_all
    return if invoice.nil?
    return unless taxable?
    return if skip_tax?
    return if invoice.contact&.tax_exempt?

    codes = invoice.company&.tax_codes&.active&.ordered&.to_a || []
    return if codes.empty?

    base_amount = BigDecimal((amount || 0).to_s)
    running     = base_amount

    codes.each do |code|
      taxable_base = code.is_compound? ? running : base_amount
      computed     = (taxable_base * code.rate / 100).round(4)
      invoice_item_taxes.create!(
        tax_code:        code,
        taxable_base:    taxable_base,
        computed_rate:   code.rate,
        computed_amount: computed
      )
      running += computed
    end
  end

  # Profit per item
  def profit
    (amount || 0) - ((cost || 0) * (quantity || 1))
  end
  
  private
  
  def calculate_amount
    self.amount = (quantity || 1) * (rate || 0)
  end
  
  def set_default_commission_type
    self.commission_type ||= 'full_commission'
  end
end
