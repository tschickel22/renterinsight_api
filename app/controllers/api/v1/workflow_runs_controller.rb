module Api
  module V1
    class WorkflowRunsController < ApplicationController
      include RbacAuthorization
      include ModuleAccessRequired
      before_action :set_company_scope
      require_module! 'management.workflows'
      before_action :set_run, only: [:show, :cancel, :retry, :steps]
      rbac_resource :workflow_automation,
        read_actions: [:index, :show, :steps],
        update_actions: [:cancel, :retry]

      def index
        runs = @company.workflow_runs
        runs = runs.where(workflow_rule_id: params[:workflow_rule_id]) if params[:workflow_rule_id].present?
        runs = runs.where(status: params[:status]) if params[:status].present?
        runs = runs.where(entity_type: params[:entity_type]) if params[:entity_type].present?
        runs = runs.where(entity_id: params[:entity_id]) if params[:entity_id].present?
        runs = runs.where('started_at >= ?', params[:from]) if params[:from].present?
        runs = runs.where('started_at <= ?', params[:to]) if params[:to].present?

        stats = {
          total: @company.workflow_runs.count,
          running: @company.workflow_runs.where(status: 'running').count,
          waiting: @company.workflow_runs.where(status: 'waiting').count,
          completed: @company.workflow_runs.where(status: 'completed').count,
          failed: @company.workflow_runs.where(status: 'failed').count
        }

        runs = runs.order(started_at: :desc)
        filtered = runs.count
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min
        runs = runs.offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: runs.map { |r| run_json(r) },
          meta: { total: filtered, page: page, per_page: per_page, total_pages: (filtered.to_f / per_page).ceil, stats: stats }
        }
      end

      def show
        render json: run_json(@run, full: true)
      end

      def cancel
        WorkflowEngine.cancel(@run, reason: params[:reason] || 'manual')
        render json: run_json(@run.reload, full: true)
      end

      def retry
        unless @run.status == 'failed'
          render json: { errors: ['Only failed runs can be retried'] }, status: :unprocessable_entity
          return
        end
        @run.update!(status: 'running', error_details: {})
        ProcessWorkflowStepJob.perform_later(@run.id)
        render json: run_json(@run.reload, full: true)
      end

      def steps
        render json: @run.workflow_run_steps.order(:created_at).map { |s|
          {
            id: s.id,
            step_id: s.step_id,
            step_type: s.step_type,
            status: s.status,
            input: s.input,
            output: s.output,
            error: s.error,
            duration_ms: s.duration_ms,
            started_at: s.started_at,
            completed_at: s.completed_at
          }
        }
      end

      private

      def set_run
        @run = @company.workflow_runs.find(params[:id])
      end

      def run_json(run, full: false)
        base = {
          id: run.id,
          workflow_rule_id: run.workflow_rule_id,
          status: run.status,
          entity_type: run.entity_type,
          entity_id: run.entity_id,
          current_step_id: run.current_step_id,
          started_at: run.started_at,
          completed_at: run.completed_at
        }
        if full
          base.merge!(
            variables: run.variables,
            rule_snapshot: run.rule_snapshot,
            error_details: run.error_details,
            wait_until: run.wait_until,
            wait_reason: run.wait_reason
          )
        end
        base
      end
    end
  end
end
