module Api
  module V1
    class WorkflowTemplatesController < ApplicationController
      include RbacAuthorization
      before_action :set_company_scope
      rbac_resource :workflow_automation,
        read_actions: [:index, :show],
        create_actions: [:activate]

      def index
        scope = WorkflowTemplate.active
        scope = scope.where(category: params[:category]) if params[:category].present?
        scope = scope.where(entity_type: params[:entity_type]) if params[:entity_type].present?
        templates = scope.to_a
        grouped = templates.group_by(&:category).each_with_object({}) do |(cat, items), h|
          h[cat] = items.map { |t| template_json(t) }
        end
        render json: { items: grouped, categories: templates.map(&:category).uniq }
      end

      def show
        template = WorkflowTemplate.find(params[:id])
        render json: template_json(template, full: true)
      end

      def activate
        template = WorkflowTemplate.find(params[:id])
        overrides = params[:parameter_overrides] || {}
        overrides = overrides.to_unsafe_h if overrides.respond_to?(:to_unsafe_h)
        rule = template.clone_to_company(@company, user: current_user, parameter_overrides: overrides)
        render json: rule_json(rule), status: :created
      end

      private

      def template_json(t, full: false)
        base = {
          id: t.id,
          key: t.key,
          name: t.name,
          description: t.description,
          category: t.category,
          entity_type: t.entity_type,
          icon: t.icon,
          preview_description: t.preview_description,
          required_integrations: t.required_integrations,
          parameter_schema: t.parameter_schema,
          sort_order: t.sort_order
        }
        if full
          base.merge!(
            trigger: t.trigger,
            conditions: t.conditions,
            steps: t.steps,
            parameters: t.parameters
          )
        end
        base
      end

      def rule_json(rule)
        {
          id: rule.id,
          name: rule.name,
          description: rule.description,
          entity_type: rule.entity_type,
          status: rule.status,
          version: rule.version,
          is_seeded: rule.is_seeded,
          halt_on_reply: rule.halt_on_reply,
          run_count: rule.workflow_runs.count,
          last_run_at: rule.workflow_runs.maximum(:started_at),
          created_at: rule.created_at,
          updated_at: rule.updated_at,
          trigger: rule.trigger,
          conditions: rule.conditions,
          steps: rule.steps,
          parameters: rule.parameters,
          template_id: rule.workflow_template_id
        }
      end
    end
  end
end
