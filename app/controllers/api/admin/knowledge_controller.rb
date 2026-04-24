# frozen_string_literal: true

module Api
  module Admin
    class KnowledgeController < ApplicationController
      before_action :authenticate_user!
      before_action :require_platform_admin!

      RESOURCE_MAP = {
        'modules'          => Knowledge::Module,
        'features'         => Knowledge::Feature,
        'articles'         => Knowledge::Article,
        'tours'            => Tour,
        'tour_steps'       => TourStep,
        'intent_patterns'  => Knowledge::IntentPattern,
        'entity_aliases'   => Knowledge::EntityAlias
      }.freeze

      def index
        klass = resolve_resource!
        return unless klass
        records = case params[:resource]
                  when 'modules'
                    klass.includes(:features).order(:position, :name).map { |mod| module_payload(mod, include_features: true) }
                  when 'features'
                    scope = klass.includes(:knowledge_module).order(:position, :name)
                    scope = scope.where(knowledge_module_id: params[:module_id]) if params[:module_id].present?
                    scope.map { |f| feature_payload(f) }
                  when 'articles'
                    scope = klass.includes(:knowledge_module, :knowledge_feature).order(updated_at: :desc)
                    scope = scope.where(status: params[:status]) if params[:status].present?
                    scope = scope.joins(:knowledge_module).where(knowledge_modules: { key: params[:module] }) if params[:module].present?
                    scope.limit(200).map { |a| article_payload(a) }
                  when 'tours'
                    klass.includes(:steps, :knowledge_module).order(:position, :name).map { |t| tour_payload(t, include_steps: true) }
                  when 'tour_steps'
                    scope = klass.order(:position)
                    scope = scope.where(tour_id: params[:tour_id]) if params[:tour_id].present?
                    scope.map { |s| step_payload(s) }
                  when 'intent_patterns'
                    klass.order(:priority, :created_at).map { |p| pattern_payload(p) }
                  when 'entity_aliases'
                    klass.order(:canonical_key, :alias_name).map { |a| alias_payload(a) }
                  else []
                  end
        render json: { params[:resource] => records }
      end

      def show
        klass = resolve_resource!
        return unless klass
        record = klass.find(params[:id])
        render json: build_payload(params[:resource], record)
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'not found' }, status: :not_found
      end

      def create
        klass = resolve_resource!
        return unless klass
        if params[:resource] == 'intent_patterns' && params[:test].present?
          return test_intent_pattern
        end
        record = klass.new(permitted_params_for(params[:resource]))
        if record.save
          render json: build_payload(params[:resource], record), status: :created
        else
          render json: { errors: record.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        klass = resolve_resource!
        return unless klass
        record = klass.find(params[:id])
        if record.update(permitted_params_for(params[:resource]))
          render json: build_payload(params[:resource], record)
        else
          render json: { errors: record.errors.full_messages }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'not found' }, status: :not_found
      end

      def destroy
        klass = resolve_resource!
        return unless klass
        klass.find(params[:id]).destroy
        head :no_content
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'not found' }, status: :not_found
      end

      def analytics
        searches = Knowledge::Search.all
        recent = searches.where('created_at > ?', 30.days.ago)
        tour_completions = (UserTourCompletion.where('completed_at > ?', 30.days.ago).count rescue 0)
        top_queries = recent.group(:query).order('count_all DESC').limit(20).count
        recent_searches = searches.order(created_at: :desc).limit(50).map do |s|
          { id: s.id, query: s.query, result_count: s.result_count, action_taken: s.action_taken, user_id: s.user_id, created_at: s.created_at }
        end
        render json: {
          stats: {
            total_searches: searches.count, searches_last_30_days: recent.count,
            avg_results: recent.average(:result_count)&.round(1) || 0,
            failed_searches: recent.where(result_count: 0).count,
            tour_completions: tour_completions,
            total_modules: Knowledge::Module.active.count,
            total_features: Knowledge::Feature.where(is_active: true).count,
            total_articles: Knowledge::Article.count,
            total_tours: Tour.where(is_active: true).count
          },
          top_queries: top_queries.map { |q, c| { query: q, count: c } },
          recent_searches: recent_searches
        }
      end

      def analytics_kind
        case params[:kind]
        when 'searches'
          render json: { searches: Knowledge::Search.order(created_at: :desc).limit(100).map { |s|
            { id: s.id, query: s.query, result_count: s.result_count, action_taken: s.action_taken, created_at: s.created_at }
          }}
        when 'tours'
          render json: { completions: (UserTourCompletion.includes(:tour).order(created_at: :desc).limit(100).map { |c|
            { id: c.id, tour_name: c.tour&.name, user_id: c.user_id, completed_at: c.completed_at }
          } rescue []) }
        when 'articles'
          render json: { articles: Knowledge::Article.includes(:knowledge_module).order(updated_at: :desc).limit(50).map { |a| article_payload(a) } }
        else
          render json: { error: 'Unknown kind' }, status: :bad_request
        end
      end

      private

      def resolve_resource!
        klass = RESOURCE_MAP[params[:resource]]
        render(json: { error: "Unknown resource: #{params[:resource]}" }, status: :bad_request) and return nil unless klass
        klass
      end

      def require_platform_admin!
        render(json: { error: 'Platform admin access required' }, status: :forbidden) unless current_user&.role == 'platform_admin'
      end

      def test_intent_pattern
        query = params[:query].to_s.strip
        return render(json: { error: 'query required' }, status: :bad_request) if query.empty?
        result = Knowledge::IntentMatcher.new(query).parse
        render json: { query: query, result: result.to_h }
      end

      def build_payload(resource, record)
        case resource
        when 'modules'          then module_payload(record, include_features: true)
        when 'features'         then feature_payload(record)
        when 'articles'         then article_payload(record, include_content: true)
        when 'tours'            then tour_payload(record, include_steps: true)
        when 'tour_steps'       then step_payload(record)
        when 'intent_patterns'  then pattern_payload(record)
        when 'entity_aliases'   then alias_payload(record)
        else record.as_json
        end
      end

      def permitted_params_for(resource)
        case resource
        when 'modules'         then params.permit(:key, :name, :icon, :route, :description, :position, :is_active)
        when 'features'        then params.permit(:knowledge_module_id, :key, :name, :route, :ui_selector, :permission_key, :position, :is_active)
        when 'articles'        then params.permit(:knowledge_module_id, :knowledge_feature_id, :slug, :title, :excerpt, :content, :content_html, :article_type, :status, :position)
        when 'tours'           then params.permit(:knowledge_module_id, :knowledge_feature_id, :name, :description, :trigger_type, :start_url, :position, :is_active)
        when 'tour_steps'      then params.permit(:tour_id, :selector, :title, :content, :placement, :highlight_type, :click_required, :input_required, :position)
        when 'intent_patterns' then params.permit(:pattern, :intent_type, :entity_key, :priority, :is_active)
        when 'entity_aliases'  then params.permit(:alias_name, :canonical_key)
        else {}
        end
      end

      def module_payload(mod, include_features: false)
        p = { id: mod.id, key: mod.key, name: mod.name, icon: mod.icon, route: mod.route,
              description: mod.description, position: mod.position, is_active: mod.is_active,
              features_count: mod.features.count }
        p[:features] = mod.features.order(:position, :name).map { |f| feature_payload(f) } if include_features
        p
      end

      def feature_payload(f)
        { id: f.id, key: f.key, name: f.name, route: f.route, ui_selector: f.ui_selector,
          permission_key: f.permission_key, position: f.position, is_active: f.is_active,
          knowledge_module_id: f.knowledge_module_id, module_key: f.knowledge_module&.key, module_name: f.knowledge_module&.name }
      end

      def article_payload(a, include_content: false)
        p = { id: a.id, slug: a.slug, title: a.title, excerpt: a.excerpt, article_type: a.article_type,
              status: a.status, knowledge_module_id: a.knowledge_module_id, knowledge_feature_id: a.knowledge_feature_id,
              module_key: a.knowledge_module&.key, module_name: a.knowledge_module&.name,
              feature_key: a.knowledge_feature&.key, position: a.position,
              updated_at: a.updated_at, created_at: a.created_at }
        p.merge!(content: a.content, content_html: a.content_html) if include_content
        p
      end

      def tour_payload(t, include_steps: false)
        p = { id: t.id, name: t.name, description: t.description, trigger_type: t.trigger_type,
              start_url: t.start_url, position: t.position, is_active: t.is_active,
              knowledge_module_id: t.knowledge_module_id, knowledge_feature_id: t.knowledge_feature_id,
              module_key: t.knowledge_module&.key, feature_key: t.knowledge_feature&.key, steps_count: t.steps.count }
        p[:steps] = t.steps.order(:position).map { |s| step_payload(s) } if include_steps
        p
      end

      def step_payload(s)
        { id: s.id, tour_id: s.tour_id, selector: s.selector, title: s.title, content: s.content,
          placement: s.placement, highlight_type: s.highlight_type, click_required: s.click_required,
          input_required: s.input_required, position: s.position }
      end

      def pattern_payload(p)
        { id: p.id, pattern: p.pattern, intent_type: p.intent_type, entity_key: p.entity_key,
          priority: p.priority, is_active: (p.respond_to?(:is_active) ? p.is_active : true) }
      end

      def alias_payload(a)
        { id: a.id, alias_name: a.alias_name, canonical_key: a.canonical_key }
      end
    end
  end
end
