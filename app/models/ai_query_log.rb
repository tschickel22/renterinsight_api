class AiQueryLog < ApplicationRecord
  belongs_to :company
  belongs_to :user, optional: true
  belongs_to :location, optional: true

  FEATURES = %w[report_ai vision_scan ai_campaign_generate ai_campaign_refine ai_audience_generate ai_audience_refine bill_scan ai_template_generate ai_sequence_generate deal_desk_ai].freeze
  STATUSES = %w[success error rate_limited no_results classified no_match disambiguation].freeze

  # AI features that draw from the company's single monthly AI query budget. Deal Desk AI
  # shares this pool with report_ai (each row stays identifiable by feature/action_name),
  # so the same cap and the same Setting key govern both.
  SHARED_AI_FEATURES = %w[report_ai deal_desk_ai].freeze

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

  # --- Shared monthly AI budget (same limit/usage logic report_ai enforces) ----
  # Limit source matches ReportAiController#get_ai_report_limit: platform admins are
  # effectively unlimited, then company Setting, then platform Setting, then a default
  # when the AI module is subscribed, else 0 (disabled).
  def self.monthly_limit_for(company, user: nil)
    return 999 if user&.role == 'platform_admin'

    company_limit = Setting.get('Company', company.id, 'ai_report_queries_monthly_limit', nil) rescue nil
    return company_limit.to_i if company_limit.present? && company_limit.to_i > 0

    platform_limit = Setting.get('Platform', 0, 'ai_report_queries_monthly_limit', nil) rescue nil
    return platform_limit.to_i if platform_limit.present? && platform_limit.to_i > 0

    has_module = (company.platform_modules.to_a.include?('management_ai_reports') rescue false)
    has_module ? 100 : 0
  end

  # Count of metered (non-rate-limited) AI rows this month across the shared features.
  def self.monthly_used_for(company, features: SHARED_AI_FEATURES)
    where(company_id: company.id, feature: features)
      .where.not(execution_status: 'rate_limited')
      .this_month.count
  end

  # True when the company has no remaining AI budget (limit 0 = disabled => always over).
  def self.over_cap?(company, user: nil)
    (monthly_limit_for(company, user: user) - monthly_used_for(company)) <= 0
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
