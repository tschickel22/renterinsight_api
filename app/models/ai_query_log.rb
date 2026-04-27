class AiQueryLog < ApplicationRecord
  belongs_to :company
  belongs_to :user, optional: true
  belongs_to :location, optional: true

  FEATURES = %w[report_ai vision_scan ai_campaign_generate ai_campaign_refine].freeze
  STATUSES = %w[success error rate_limited no_results classified no_match disambiguation].freeze

  validates :feature, inclusion: { in: FEATURES }
  validates :execution_status, inclusion: { in: STATUSES }

  scope :for_feature, ->(f) { where(feature: f) }
  scope :this_month, -> { where('created_at >= ?', Time.current.beginning_of_month) }
  scope :successful, -> { where(execution_status: 'success') }

  # Most common questions across a company (for learning/canning)
  def self.popular_questions(company_id, feature: 'report_ai', limit: 20)
    where(company_id: company_id, feature: feature, execution_status: 'success')
      .where.not(question: [nil, ''])
      .group(:question, :module_key)
      .order('count_all DESC')
      .limit(limit)
      .count
      .map { |(q, mod), count| { question: q, module_key: mod, count: count } }
  end

  # Most common across ALL companies (platform-level insight)
  def self.platform_popular_questions(feature: 'report_ai', limit: 50)
    where(feature: feature, execution_status: 'success')
      .where.not(question: [nil, ''])
      .group(:question, :module_key)
      .order('count_all DESC')
      .limit(limit)
      .count
      .map { |(q, mod), count| { question: q, module_key: mod, count: count } }
  end

  # Monthly cost summary per company
  def self.monthly_cost_summary(company_id)
    where(company_id: company_id)
      .this_month
      .group(:feature)
      .sum(:cost_cents)
      .transform_values { |cents| (cents.to_f / 100).round(4) }
  end
end
