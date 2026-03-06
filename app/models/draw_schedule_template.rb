class DrawScheduleTemplate < ApplicationRecord
  belongs_to :company

  validates :name, presence: true
  validates :draws, presence: true
  validate :draws_must_sum_to_100

  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :default_template, -> { where(is_default: true) }

  # Format: [{ "percentage" => 10, "description" => "Due upon closing", "position" => 1 }, ...]
  
  # Calculate draw amounts from a total
  def calculate_draws(total_amount)
    (draws || []).map do |draw|
      pct = draw['percentage'].to_f
      {
        'percentage' => pct,
        'description' => draw['description'],
        'position' => draw['position'],
        'amount' => (total_amount * pct / 100.0).round(2)
      }
    end.sort_by { |d| d['position'] }
  end

  # Build a draw_schedule hash for storing on an invoice
  def to_invoice_schedule(total_amount)
    {
      'template_name' => name,
      'template_id' => id,
      'total_amount' => total_amount.to_f,
      'draws' => calculate_draws(total_amount)
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
