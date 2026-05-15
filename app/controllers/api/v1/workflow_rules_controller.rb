module Api
  module V1
    class WorkflowRulesController < ApplicationController
      include RbacAuthorization
      include ModuleAccessRequired
      before_action :set_company_scope
      require_module! 'management.workflows'
      before_action :set_rule, only: [:show, :update, :destroy, :activate, :pause, :resume, :archive, :validate, :runs, :preview]
      rbac_resource :workflow_automation,
        read_actions: [:index, :show, :runs, :validate, :preview, :preview_unsaved],
        create_actions: [:create, :ai_generate, :ai_accept, :ai_refine],
        update_actions: [:update, :activate, :pause, :resume, :archive],
        delete_actions: [:destroy]

      def index
        rules = @company.workflow_rules.where.not(status: 'archived')
        rules = rules.where(entity_type: params[:entity_type]) if params[:entity_type].present?
        rules = rules.where(status: params[:status]) if params[:status].present?
        stats = {
          total: @company.workflow_rules.where.not(status: 'archived').count,
          draft: @company.workflow_rules.where(status: 'draft').count,
          active: @company.workflow_rules.where(status: 'active').count,
          paused: @company.workflow_rules.where(status: 'paused').count
        }
        if params[:search].present?
          term = "%#{params[:search]}%"
          rules = rules.where('name ILIKE ? OR description ILIKE ?', term, term)
        end
        rules = rules.order(updated_at: :desc)
        filtered = rules.count
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min
        rules = rules.offset((page - 1) * per_page).limit(per_page)
        render json: { items: rules.map { |r| rule_json(r) }, meta: { total: filtered, page: page, per_page: per_page, total_pages: (filtered.to_f / per_page).ceil, stats: stats } }
      end

      def show
        render json: rule_json(@rule, full: true)
      end

      def create
        rule = @company.workflow_rules.build(rule_params)
        rule.status = 'draft'
        rule.created_by_user_id = current_user&.id
        if rule.save
          render json: rule_json(rule, full: true), status: :created
        else
          render json: { errors: rule.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        if @rule.update(rule_params)
          render json: rule_json(@rule, full: true)
        else
          render json: { errors: @rule.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @rule.workflow_runs.active.find_each do |run|
          run.update!(status: 'cancelled', completed_at: Time.current, error_details: { reason: 'rule_deleted' })
        end
        @rule.destroy!
        render json: { message: 'Workflow deleted successfully' }
      end

      def activate
        validation = WorkflowRuleValidator.new(@rule).validate
        if validation.valid?
          @rule.update!(status: 'active')
          render json: rule_json(@rule, full: true)
        else
          render json: {
            error: 'Workflow cannot be activated',
            validation_errors: validation.structured_errors,
            errors: validation.errors
          }, status: :unprocessable_entity
        end
      end

      def pause
        @rule.update!(status: 'paused')
        render json: rule_json(@rule)
      end

      def resume
        @rule.update!(status: 'active')
        render json: rule_json(@rule)
      end

      def archive
        @rule.update!(status: 'archived')
        render json: rule_json(@rule)
      end

      def validate
        validation = WorkflowRuleValidator.new(@rule).validate
        render json: {
          valid: validation.valid?,
          errors: validation.errors,
          validation_errors: validation.structured_errors,
          warnings: validation.warnings
        }
      end

      def runs
        runs = @rule.workflow_runs.order(started_at: :desc).limit(100)
        render json: runs.map { |r| run_json(r) }
      end

      # POST /api/v1/workflow_rules/:id/preview
      def preview
        result = WorkflowPreviewService.preview(@rule, company: @company)
        render json: result
      end

      # POST /api/v1/workflow_rules/preview (collection — unsaved rule)
      def preview_unsaved
        rule = @company.workflow_rules.new(rule_params)
        result = WorkflowPreviewService.preview(rule, company: @company)
        render json: result
      end

      # POST /api/v1/workflow_rules/ai_generate
      def ai_generate
        return unless authorize_action!('workflow_automation', 'create')
        builder = Workflows::AiBuilder.new(company: @company, user: current_user)
        generation = builder.generate(
          prompt: params[:prompt],
          context_overrides: params[:context_overrides]&.to_unsafe_h
        )
        render json: {
          generation_id: generation.id,
          plan: generation.generated_plan,
          has_questions: generation.generated_plan['questions'].present?
        }
      rescue Workflows::AiBuilder::CreditLimitError => e
        render json: { error: e.message, code: 'credit_limit' }, status: :too_many_requests
      rescue Workflows::AiBuilder::GenerationError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/workflow_rules/ai_accept
      def ai_accept
        return unless authorize_action!('workflow_automation', 'create')
        generation = @company.workflow_ai_generations.find(params[:generation_id])
        builder = Workflows::AiBuilder.new(company: @company, user: current_user)
        rule = builder.accept(generation: generation)
        render json: rule_json(rule, full: true), status: :created
      end

      # POST /api/v1/workflow_rules/ai_refine
      def ai_refine
        return unless authorize_action!('workflow_automation', 'create')
        generation = @company.workflow_ai_generations.find(params[:generation_id])
        builder = Workflows::AiBuilder.new(company: @company, user: current_user)
        new_gen = builder.refine(generation: generation, feedback: params[:feedback])
        render json: {
          generation_id: new_gen.id,
          plan: new_gen.generated_plan,
          has_questions: new_gen.generated_plan['questions'].present?
        }
      rescue Workflows::AiBuilder::CreditLimitError => e
        render json: { error: e.message, code: 'credit_limit' }, status: :too_many_requests
      rescue Workflows::AiBuilder::GenerationError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def set_rule
        @rule = @company.workflow_rules.find(params[:id])
      end

      def rule_params
        permitted = params.require(:workflow_rule).permit(
          :name, :description, :entity_type, :halt_on_reply,
          trigger: {},
          steps: {},
          parameters: {}
        )
        raw_conditions = params.dig(:workflow_rule, :conditions)
        unless raw_conditions.nil?
          permitted[:conditions] = if raw_conditions.respond_to?(:permit!)
            raw_conditions.permit!.to_h
          elsif raw_conditions.is_a?(Array)
            raw_conditions.map { |item| item.respond_to?(:permit!) ? item.permit!.to_h : item }
          else
            raw_conditions
          end
        end
        permitted
      end

      def rule_json(rule, full: false)
        base = {
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
          updated_at: rule.updated_at
        }
        if full
          base.merge!(
            trigger: rule.trigger,
            conditions: rule.conditions,
            steps: rule.steps,
            parameters: rule.parameters,
            template_id: rule.workflow_template_id
          )
        end
        base
      end

      def run_json(run)
        {
          id: run.id,
          status: run.status,
          entity_type: run.entity_type,
          entity_id: run.entity_id,
          current_step_id: run.current_step_id,
          started_at: run.started_at,
          completed_at: run.completed_at
        }
      end
    end
  end
end
