class WinLossReport < ApplicationRecord
  belongs_to :deal
  belongs_to :user, optional: true
  
  validates :result, presence: true, inclusion: { in: %w[won lost] }
  validates :deal_quality_score, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 10 }, allow_nil: true
  validates :sales_process_score, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 10 }, allow_nil: true
  validates :product_fit_score, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 10 }, allow_nil: true
  
  scope :won, -> { where(result: 'won') }
  scope :lost, -> { where(result: 'lost') }
  scope :by_reason, ->(reason) { where(primary_reason: reason) }
  scope :with_competitor, ->(competitor) { where(competitor: competitor) }
  scope :recent, -> { order(created_at: :desc) }
  
  def self.win_rate
    total = count
    return 0 if total.zero?
    (won.count.to_f / total * 100).round(2)
  end
  
  def self.top_win_reasons(limit = 5)
    won.group(:primary_reason).count.sort_by { |_, count| -count }.first(limit)
  end
  
  def self.top_loss_reasons(limit = 5)
    lost.group(:primary_reason).count.sort_by { |_, count| -count }.first(limit)
  end
  
  def self.top_competitors(limit = 5)
    lost.where.not(competitor: [nil, '']).group(:competitor).count.sort_by { |_, count| -count }.first(limit)
  end
end
