# frozen_string_literal: true

# Platform view of campaign email volume against each company's monthly allowance.
# Mirrors Api::Platform::SmsUsageController.
#
# Usage is counted from campaign_sends rather than a dedicated usage log, since every
# billable campaign email already creates exactly one row there. CampaignSend.real excludes
# test-send enrollments so a dry run does not bill.
class Api::Platform::EmailUsageController < ApplicationController
  before_action :require_platform_admin!

  # GET /api/platform/email_usage
  def index
    period = params[:period] || EmailCapService.current_billing_period
    range = period_range(period)

    counts = CampaignSend.real
                         .where(sent_at: range)
                         .group(:company_id)
                         .count

    bounced = CampaignSend.real
                          .where(sent_at: range)
                          .where.not(bounced_at: nil)
                          .group(:company_id)
                          .count

    delivered = CampaignSend.real
                            .where(sent_at: range)
                            .where.not(delivered_at: nil)
                            .group(:company_id)
                            .count

    companies = Company.where(id: counts.keys).index_by(&:id)

    rows = counts.map do |company_id, total|
      company = companies[company_id]
      next if company.nil?

      limit = company.email_monthly_limit.to_i
      pct = limit.positive? ? (total.to_f / limit * 100).round(1) : 0

      {
        company_id: company.id,
        company_name: company.name,
        email_monthly_limit: limit,
        total_emails: total,
        usage_percent: pct,
        # Delivered is SES-only. A company sending through OAuth mailboxes reports zero
        # here because Gmail and Graph give no positive receipt, which is not a fault.
        delivered: delivered[company_id].to_i,
        bounced: bounced[company_id].to_i,
        verified_sending_domains: CompanyDomain.email_verified.where(company_id: company.id).pluck(:hostname),
        status: cap_status(pct)
      }
    end.compact.sort_by { |r| -r[:total_emails] }

    render json: { billing_period: period, companies: rows }
  end

  # GET /api/platform/email_usage/:company_id
  def show
    company = Company.find(params[:company_id])
    period = params[:period] || EmailCapService.current_billing_period

    history = (0..5).map do |months_ago|
      month = months_ago.months.ago
      key = month.strftime('%Y-%m')
      { period: key }.merge(summary_for(company, period_range(key)))
    end

    render json: {
      company_id: company.id,
      company_name: company.name,
      email_monthly_limit: company.email_monthly_limit,
      billing_period: period,
      summary: summary_for(company, period_range(period)),
      sending_domains: CompanyDomain.where(company_id: company.id).email_enabled.map do |d|
        { hostname: d.hostname, status: d.email_status, verified_at: d.email_verified_at }
      end,
      history: history
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Company not found' }, status: :not_found
  end

  # PATCH /api/platform/email_usage/:company_id/set_limit
  def set_limit
    company = Company.find(params[:company_id])
    limit = params[:email_monthly_limit].to_i

    if limit.negative?
      return render json: { error: 'Limit must be 0 or greater (0 = unlimited)' },
                    status: :unprocessable_entity
    end

    company.update!(email_monthly_limit: limit)

    render json: {
      company_id: company.id,
      email_monthly_limit: company.email_monthly_limit,
      message: "Email limit updated to #{limit.zero? ? 'unlimited' : "#{limit}/month"}"
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Company not found' }, status: :not_found
  end

  private

  def period_range(period)
    start = Time.zone.parse("#{period}-01")
    start..start.end_of_month
  rescue StandardError
    EmailCapService.period_start..Time.current.end_of_month
  end

  def summary_for(company, range)
    scope = CampaignSend.real.where(company_id: company.id, sent_at: range)

    {
      total_emails: scope.count,
      delivered: scope.where.not(delivered_at: nil).count,
      bounced: scope.where.not(bounced_at: nil).count,
      opened: scope.where.not(opened_at: nil).count,
      clicked: scope.where.not(clicked_at: nil).count
    }
  end

  def cap_status(pct)
    return 'over_cap' if pct >= 100
    return 'approaching_cap' if pct >= 80

    'ok'
  end
end
