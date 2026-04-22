# frozen_string_literal: true

module Api
  module Admin
    # Platform-admin-only CRUD over the knowledge base. Supports modules,
    # features, articles, tours, tour_steps, intent_patterns, plus an analytics
    # summary at GET /api/admin/knowledge/analytics.
    #
    # Scoped by ?resource=… on collection-level endpoints to avoid proliferating
    # a dozen controllers. Items are addressed at :id.
    class KnowledgeController < ApplicationController
      before_action :authenticate_user!
      before_action :require_platform_admin!

      RESOURCE_MODELS = {
        'modules'         => Knowledge::Module,
        'features'        => Knowledge::Feature,
        'articles'        => Knowledge::Article,
        'tours'           => ::Tour,
        'tour_steps'      => ::TourStep,
        'intent_patterns' => Knowledge::IntentPattern,
        'entity_aliases'  => Knowledge::EntityAlias,
        'ui_elements'     => Knowledge::UiElement,
        'marketing_content' => ::MarketingContent
      }.freeze

      # GET /api/admin/knowledge/:resource
      def index
        klass = resource_model
        return unless klass

        scope = klass.all
        scope = scope.where(knowledge_module_id: params[:knowledge_module_id]) if params[:knowledge_module_id].present? && klass.column_names.include?('knowledge_module_id')
        scope = scope.order(:id).limit(params[:limit].presence || 500)

        render json: { resource: params[:resource], items: scope.as_json }
      end

      # GET /api/admin/knowledge/:resource/:id
      def show
        klass = resource_model
        return unless klass
        item = klass.find_by(id: params[:id])
        return render json: { error: 'not found' }, status: :not_found unless item
        render json: item.as_json
      end

      # POST /api/admin/knowledge/:resource
      def create
        klass = resource_model
        return unless klass
        item = klass.new(record_params(klass))
        if item.save
          after_save_hook(item)
          render json: item.as_json, status: :created
        else
          render json: { errors: item.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/admin/knowledge/:resource/:id
      def update
        klass = resource_model
        return unless klass
        item = klass.find_by(id: params[:id])
        return render json: { error: 'not found' }, status: :not_found unless item
        if item.update(record_params(klass))
          after_save_hook(item)
          render json: item.as_json
        else
          render json: { errors: item.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/admin/knowledge/:resource/:id
      def destroy
        klass = resource_model
        return unless klass
        item = klass.find_by(id: params[:id])
        return render json: { error: 'not found' }, status: :not_found unless item
        item.destroy
        render json: { ok: true }
      end

      # GET /api/admin/knowledge/analytics/:kind (kind = searches|tours|articles)
      # Per-tab analytics splits. FE calls these on the Analytics sub-tabs.
      def analytics_kind
        since = (params[:days].presence || 30).to_i.days.ago
        window = (params[:days].presence || 30).to_i

        case params[:kind]
        when 'searches'
          searches = Knowledge::Search.where('created_at >= ?', since)
          total    = searches.count
          acted    = searches.where.not(action_taken: nil).count
          zero     = searches.where(result_count: 0).count
          top      = searches.group(:query)
                             .order(Arel.sql('COUNT(*) DESC'))
                             .limit(20)
                             .count
          render json: {
            window_days:        window,
            total_searches:     total,
            actioned_searches:  acted,
            zero_result_searches: zero,
            click_through_rate: total.zero? ? 0.0 : (acted.to_f / total).round(3),
            items: top.map { |q, c| { query: q, count: c } }
          }
        when 'tours'
          rows = UserTourCompletion
                   .joins(:tour)
                   .where('user_tour_completions.created_at >= ?', since)
                   .group('tours.key')
                   .select('tours.key, COUNT(*) AS starts, COUNT(completed_at) AS completions')
          items = rows.map do |r|
            starts      = r.starts.to_i
            completions = r.completions.to_i
            { tour: r.key, starts: starts, completions: completions,
              completion_rate: starts.zero? ? 0.0 : (completions.to_f / starts).round(3) }
          end
          render json: { window_days: window, items: items }
        when 'articles'
          articles   = Knowledge::Article.all
          total      = articles.count
          published  = articles.where(is_published: true).count
          by_module  = articles
                         .joins('LEFT JOIN knowledge_modules ON knowledge_modules.id = knowledge_articles.knowledge_module_id')
                         .group('knowledge_modules.key')
                         .count
          items = by_module.map { |k, c| { module: k || 'uncategorized', count: c } }
          render json: { total: total, published: published, items: items }
        else
          render json: { error: "unknown analytics kind '#{params[:kind]}'" }, status: :bad_request
        end
      end

      # GET /api/admin/knowledge/analytics
      # Top queries, intent distribution, conversion (action_taken != nil).
      def analytics
        since = (params[:days].presence || 30).to_i.days.ago

        searches = Knowledge::Search.where('created_at >= ?', since)
        total    = searches.count
        acted    = searches.where.not(action_taken: nil).count

        top_queries = searches.group(:query)
                              .order(Arel.sql('COUNT(*) DESC'))
                              .limit(20)
                              .count

        intent_breakdown = searches.group(:intent_detected).count

        tour_progress = UserTourCompletion
                        .joins(:tour)
                        .group('tours.key')
                        .select('tours.key, COUNT(*) AS starts, COUNT(completed_at) AS completions')
                        .map { |row| { tour: row.key, starts: row.starts.to_i, completions: row.completions.to_i } }

        render json: {
          window_days:       (params[:days].presence || 30).to_i,
          total_searches:    total,
          actioned_searches: acted,
          click_through_rate: total.zero? ? 0.0 : (acted.to_f / total).round(3),
          top_queries:        top_queries,
          intent_breakdown:   intent_breakdown,
          tour_progress:      tour_progress
        }
      end

      private

      def resource_model
        # FE sends hyphenated names (intent-patterns); normalize to snake_case.
        key = params[:resource].to_s.tr('-', '_')
        klass = RESOURCE_MODELS[key]
        unless klass
          render json: { error: "unknown resource '#{params[:resource]}'" }, status: :bad_request
          return nil
        end
        klass
      end

      # Permit all writable columns for the chosen model except timestamps/id.
      # Simple and safe because this endpoint is gated behind platform_admin.
      def record_params(klass)
        permitted = klass.column_names - %w[id created_at updated_at]
        params.require(:item).permit(*permitted).to_h
      end

      def after_save_hook(item)
        # Regenerate the embedding asynchronously on article save. Synchronous
        # would block the response on an external API call — no thanks.
        return unless item.is_a?(Knowledge::Article)
        return unless defined?(Knowledge::EmbeddingService)

        Thread.new { Knowledge::EmbeddingService.update_article(item) } if Rails.env.production?
      end
    end
  end
end
