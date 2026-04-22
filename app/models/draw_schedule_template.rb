class DrawScheduleTemplate < ApplicationRecord
  belongs_to :company

  validates :name, presence: true
  validates :draws, presence: true
  validate :draws_must_sum_to_100

  # addon_mode: how add-on line items (concrete, septic, HVAC, etc.) are handled
  #   "included"    — (Default) Draw percentages are of the TOTAL INVOICE price.
  #                    Add-on amounts are subtracted from / included in draw amounts.
  #   "additional"  — Draw percentages are of the HOME PURCHASE PRICE only.
  #                    Add-on items are listed as extra charges on the draw they belong to,
  #                    added ON TOP of the home-price draw amount.
  ADDON_MODES = %w[included additional].freeze
  validates :addon_mode, inclusion: { in: ADDON_MODES }, allow_nil: true

  TAX_TIMINGS = %w[per_draw final_draw].freeze
  validates :tax_timing, inclusion: { in: TAX_TIMINGS }, allow_nil: true

  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :default_template, -> { where(is_default: true) }

  # Format: [{ "percentage" => 10, "description" => "Due upon closing", "position" => 1,
  #            "sub_items" => [{ "description" => "Concrete Foundation", "position" => 1 }] }, ...]

  # Returns effective addon_mode (defaults to 'included' for backward compat)
  def effective_addon_mode
    addon_mode.presence || 'included'
  end

  # Calculate draw amounts from a total
  #
  # When addon_mode == 'included': percentages apply to total_amount (add-ons already in total).
  # When addon_mode == 'additional': percentages apply to home_price only; sub_item amounts
  #   are listed separately and summed on top.
  #
  # @param total_amount [Float] The full invoice total
  # @param home_price   [Float, nil] The home-only price (required when addon_mode == 'additional')
  def calculate_draws(total_amount, home_price: nil)
    base = if effective_addon_mode == 'additional' && home_price.present?
             home_price.to_f
           else
             total_amount.to_f
           end

    (draws || []).map do |draw|
      pct = draw['percentage'].to_f
      draw_amount = (base * pct / 100.0).round(2)

      result = {
        'percentage' => pct,
        'description' => draw['description'],
        'position' => draw['position'],
        'amount' => draw_amount
      }

      # Pass through sub_items with their amounts (if any were saved per-invoice)
      if draw['sub_items'].present?
        result['sub_items'] = draw['sub_items'].map do |si|
          {
            'description' => si['description'],
            'amount' => si['amount'].to_f,
            'position' => si['position']
          }
        end

        # In 'additional' mode, sub_item amounts are added on top of the draw
        if effective_addon_mode == 'additional'
          sub_total = result['sub_items'].sum { |si| si['amount'].to_f }
          result['draw_subtotal'] = draw_amount              # Home-price portion only
          result['addons_subtotal'] = sub_total.round(2)     # Add-ons total
          result['amount'] = (draw_amount + sub_total).round(2)  # Combined draw total
        end
      end

      result
    end.sort_by { |d| d['position'] }
  end

  # Build a draw_schedule hash for storing on an invoice
  def to_invoice_schedule(total_amount, home_price: nil)
    {
      'template_name' => name,
      'template_id' => id,
      'addon_mode' => effective_addon_mode,
      'total_amount' => total_amount.to_f,
      'home_price' => home_price&.to_f,
      'draws' => calculate_draws(total_amount, home_price: home_price)
    }
  end

  private

  def draws_must_sum_to_100
    return if draws.blank?

    total = draws.sum { |d| d['percentage'].to_f }
    unless (total - 100.0).abs < 0.01
      errors.add(:draws, "percentages must sum to 100% (currently #{total}%)")
    end
  end
end
