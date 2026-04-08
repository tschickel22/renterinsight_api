module Api
  module V1
    class WorkflowMetricsController < ApplicationController
      include RbacAuthorization
      before_action :set_company_scope
      rbac_resource :workflow_automation, read_actions: [:index]

      def index
        rules = @company.workflow_rules
        runs = @company.workflow_runs

        total_rules = {
          draft: rules.where(status: 'draft').count,
          active: rules.where(status: 'active').count,
          paused: rules.where(status: 'paused').count,
          archived: rules.where(status: 'archived').count
        }

        runs_24h = runs.where(started_at: 24.hours.ago..).count
        runs_7d_scope = runs.where(started_at: 7.days.ago..)
        runs_7d = runs_7d_scope.count

        completed_7d = runs_7d_scope.where(status: 'completed').count
        failed_7d = runs_7d_scope.where(status: 'failed').count
        denom = completed_7d + failed_7d
        success_rate_7d = denom.zero? ? nil : (completed_7d.to_f / denom).round(4)

        completed_runs = runs_7d_scope.where(status: 'completed').where.not(completed_at: nil)
        durations = completed_runs.pluck(:started_at, :completed_at).map { |s, c| ((c - s) * 1000).to_i }
        avg_duration_ms = durations.empty? ? nil : (durations.sum / durations.size)

        top_5_volume = runs_7d_scope.group(:workflow_rule_id).order('count_all desc').limit(5).count
        top_5_volume_with_names = top_5_volume.map { |rid, cnt|
          r = rules.find_by(id: rid)
          { workflow_rule_id: rid, name: r&.name, count: cnt }
        }

        top_5_failed = runs_7d_scope.where(status: 'failed').group(:workflow_rule_id).order('count_all desc').limit(5).count
        top_5_failed_with_names = top_5_failed.map { |rid, cnt|
          r = rules.find_by(id: rid)
          { workflow_rule_id: rid, name: r&.name, count: cnt }
        }

        render json: {
          total_rules: total_rules,
          runs_last_24h: runs_24h,
          runs_last_7d: runs_7d,
          success_rate_7d: success_rate_7d,
          avg_duration_ms: avg_duration_ms,
          top_5_rules_by_volume: top_5_volume_with_names,
          top_5_failed_rules: top_5_failed_with_names,
          waiting_runs_count: runs.where(status: 'waiting').count
        }
      end
    end
  end
end
