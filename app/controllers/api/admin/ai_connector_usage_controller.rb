# frozen_string_literal: true

# Which dealers have the AI connector and how much they use it (backlog E53).
#
# Cross-tenant on purpose: this is the platform operator's view, for billing
# the add-on and for spotting a tenant whose use looks like an export.
# require_platform_admin! checks original_user, so it stays closed during
# impersonation.
class Api::Admin::AiConnectorUsageController < ApplicationController
  before_action :require_platform_admin!

  MODULE_KEY = Oauth::AccessPolicy::MODULE_KEY

  def index
    window = (30.days.ago..)
    company_ids = candidate_company_ids
    companies = Company.where(id: company_ids).order(:name).to_a

    grants = OauthGrant.active.where(company_id: company_ids).group(:company_id)
    connections = grants.count
    people = grants.distinct.count(:user_id)
    calls = McpToolCall.where(company_id: company_ids, created_at: window)
    calls_30 = calls.group(:company_id).count
    calls_7 = calls.where(created_at: 7.days.ago..).group(:company_id).count
    records_30 = calls.group(:company_id).sum(:result_count)
    denied_30 = calls.where(status: 'denied').group(:company_id).count
    last_used = OauthGrant.where(company_id: company_ids).group(:company_id).maximum(:last_used_at)
    alert_counts = Notification.where(company_id: company_ids, notification_type: 'ai_connector_alert', created_at: window)
                               .group(:company_id).distinct.count(Arel.sql("metadata->>'alert_key'"))

    rows = companies.map do |c|
      {
        company_id: c.id, company: c.name, status: c.status,
        enabled: ModuleAccessService.new(c).has_module?(MODULE_KEY),
        connections: connections[c.id] || 0, people: people[c.id] || 0,
        calls_7_days: calls_7[c.id] || 0, calls_30_days: calls_30[c.id] || 0,
        records_30_days: records_30[c.id] || 0, refused_30_days: denied_30[c.id] || 0,
        alerts_30_days: alert_counts[c.id] || 0, last_used_at: last_used[c.id]
      }
    end

    render json: {
      totals: {
        tenants_enabled: rows.count { |r| r[:enabled] },
        connections: rows.sum { |r| r[:connections] },
        calls_30_days: rows.sum { |r| r[:calls_30_days] },
        records_30_days: rows.sum { |r| r[:records_30_days] }
      },
      tenants: rows,
      apps: McpToolCall.where(company_id: company_ids, created_at: window).group(:client_name).count
    }
  end

  private

  # Every tenant that has the add-on or has ever used it: an override row, a
  # plan that includes it, or a connection (which outlives the add-on being
  # switched off, and is worth seeing).
  def candidate_company_ids
    overrides = TenantModuleOverride.where(module_key: MODULE_KEY).pluck(:company_id)
    plan_ids = SubscriptionPlanModule.where(module_key: MODULE_KEY, is_enabled: true).pluck(:subscription_plan_id)
    on_plans = plan_ids.any? ? TenantSubscription.where(subscription_plan_id: plan_ids).pluck(:company_id) : []
    (overrides + on_plans + OauthGrant.distinct.pluck(:company_id)).uniq
  end
end
