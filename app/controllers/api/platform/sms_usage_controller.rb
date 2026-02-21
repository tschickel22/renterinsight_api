# frozen_string_literal: true

class Api::Platform::SmsUsageController < ApplicationController
  before_action :require_platform_admin!

  # GET /api/platform/sms_usage
  # Usage summary across all companies for a given billing period
  def index
    period = params[:period] || SmsUsageLog.current_billing_period

    companies_with_usage = Company.joins(
      "LEFT JOIN sms_usage_logs ON sms_usage_logs.company_id = companies.id
       AND sms_usage_logs.billing_period = #{ActiveRecord::Base.connection.quote(period)}"
    ).select(
      'companies.id,
       companies.name,
       companies.sms_monthly_limit,
       COALESCE(SUM(sms_usage_logs.message_count), 0) AS total_messages,
       COALESCE(SUM(sms_usage_logs.twilio_cost), 0)   AS total_cost,
       COALESCE(SUM(CASE WHEN sms_usage_logs.direction = \'outbound\' THEN sms_usage_logs.message_count ELSE 0 END), 0) AS outbound_count,
       COALESCE(SUM(CASE WHEN sms_usage_logs.direction = \'inbound\'  THEN sms_usage_logs.message_count ELSE 0 END), 0) AS inbound_count,
       COALESCE(SUM(CASE WHEN sms_usage_logs.source = \'manual\'    THEN sms_usage_logs.message_count ELSE 0 END), 0) AS manual_count,
       COALESCE(SUM(CASE WHEN sms_usage_logs.source = \'sequence\'  THEN sms_usage_logs.message_count ELSE 0 END), 0) AS sequence_count'
    ).group('companies.id, companies.name, companies.sms_monthly_limit')
     .order('total_messages DESC')

    render json: {
      billing_period: period,
      companies: companies_with_usage.map do |c|
        total    = c.total_messages.to_i
        limit    = c.sms_monthly_limit.to_i
        pct      = limit > 0 ? (total.to_f / limit * 100).round(1) : 0

        {
          company_id:        c.id,
          company_name:      c.name,
          sms_monthly_limit: limit,
          total_messages:    total,
          usage_percent:     pct,
          total_cost:        c.total_cost.to_f.round(4),
          outbound:          c.outbound_count.to_i,
          inbound:           c.inbound_count.to_i,
          manual:            c.manual_count.to_i,
          sequence:          c.sequence_count.to_i,
          status:            pct >= 100 ? 'over_cap' : pct >= 80 ? 'approaching_cap' : 'ok'
        }
      end
    }
  end

  # GET /api/platform/sms_usage/:company_id
  # Detailed usage for a single company with month-over-month history
  def show
    company = Company.find(params[:company_id])
    period  = params[:period] || SmsUsageLog.current_billing_period
    summary = SmsUsageLog.period_summary(company, period)

    # Last 6 months trend
    history = (0..5).map do |months_ago|
      p = months_ago.months.ago.strftime('%Y-%m')
      s = SmsUsageLog.period_summary(company, p)
      { period: p }.merge(s)
    end

    render json: {
      company_id:        company.id,
      company_name:      company.name,
      sms_monthly_limit: company.sms_monthly_limit,
      billing_period:    period,
      summary:           summary,
      history:           history
    }

  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Company not found' }, status: :not_found
  end

  # PATCH /api/platform/sms_usage/:company_id/set_limit
  # Update a company's monthly SMS cap
  def set_limit
    company = Company.find(params[:company_id])
    limit   = params[:sms_monthly_limit].to_i

    if limit < 0
      render json: { error: 'Limit must be 0 or greater (0 = unlimited)' }, status: :unprocessable_entity
      return
    end

    company.update!(sms_monthly_limit: limit)
    render json: {
      company_id:        company.id,
      sms_monthly_limit: company.sms_monthly_limit,
      message:           "SMS limit updated to #{limit == 0 ? 'unlimited' : limit.to_s + '/month'}"
    }

  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Company not found' }, status: :not_found
  end
end
