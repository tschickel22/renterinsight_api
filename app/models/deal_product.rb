class DealProduct < ApplicationRecord
  belongs_to :deal
  belongs_to :product, optional: true
  
  validates :product_name, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :unit_price, numericality: true  # Allow negative values for discounts/credits
  validates :discount_type, inclusion: { in: %w[fixed percentage], message: "%{value} is not a valid discount type" }, allow_nil: false
  
  before_save :calculate_total
  after_save :update_deal_value
  after_save :sync_deal_vehicle_from_line_item
  after_destroy :update_deal_value

  # SKU written by DealProductsController#build_sku for vehicle line items.
  VEHICLE_SKU_PATTERN = /\AVEHICLE-(\d+)\z/i

  def vehicle_line_item?
    product_sku.to_s.match?(VEHICLE_SKU_PATTERN)
  end

  def referenced_vehicle_id
    match = product_sku.to_s.match(VEHICLE_SKU_PATTERN)
    match && match[1].to_i
  end

  private

  def calculate_total
    # Calculate subtotal
    subtotal = quantity * unit_price
    
    # Apply discount based on type
    discount_amount = if discount_type == 'percentage'
      subtotal * (discount / 100.0)
    else
      discount
    end
    
    # Calculate final total
    self.total = subtotal - discount_amount + tax
  end
  
  def update_deal_value
    deal.update(value: deal.deal_products.sum(:total))
  end

  # Safety net: if the controller path skipped linking deal.vehicle_id (legacy clients,
  # custom integrations, etc.), recover by linking from the line item itself. Conservative:
  #   - only fires for SKU-tagged vehicle rows (no name-guessing)
  #   - only when deal.vehicle_id is currently nil
  #   - only when exactly one vehicle-tagged row exists on this deal (avoid picking when
  #     multiple vehicles are present and the "primary" is ambiguous)
  #   - never overwrites an existing vehicle_id
  def sync_deal_vehicle_from_line_item
    return unless vehicle_line_item?

    deal.reload
    return if deal.vehicle_id.present?

    candidate_ids = deal.deal_products
      .where('product_sku ~* ?', '^VEHICLE-[0-9]+$')
      .pluck(:product_sku)
      .map { |sku| sku.to_s.match(VEHICLE_SKU_PATTERN)&.[](1)&.to_i }
      .compact
      .uniq

    if candidate_ids.size != 1
      Rails.logger.info(
        "[DealProduct] Deal #{deal_id}: #{candidate_ids.size} vehicle line items present " \
        "(#{candidate_ids.inspect}); not auto-linking deal.vehicle_id."
      ) if candidate_ids.size > 1
      return
    end

    vehicle_id = candidate_ids.first
    return unless deal.company_id.present?

    unless Vehicle.where(id: vehicle_id, company_id: deal.company_id).exists?
      Rails.logger.warn(
        "[DealProduct] Deal #{deal_id}: vehicle #{vehicle_id} not found in company " \
        "#{deal.company_id}; not auto-linking."
      )
      return
    end

    # Use update (not update_columns) so sync_vehicle_pricing fills in selling_price/cost
    # if blank — mirrors what the proper Deal create + vehicle assignment flow does.
    deal.update(vehicle_id: vehicle_id)
    Rails.logger.info("[DealProduct] Deal #{deal_id}: auto-linked vehicle_id=#{vehicle_id} from line item.")
  rescue StandardError => e
    Rails.logger.error("[DealProduct] sync_deal_vehicle_from_line_item failed for deal #{deal_id}: #{e.message}")
  end
end
