# frozen_string_literal: true

module Api
  module V1
    class KnowledgeController < ApplicationController
      before_action :authenticate_user!

      # POST /api/v1/knowledge/search
      # body: { query: "how do I add a new lead" }
      def search
        query = params[:query].to_s.strip
        return render json: { error: 'query is required' }, status: :bad_request if query.empty?

        results = Knowledge::SmartSearchService.new(query, user: current_user).search
        render json: { query: query, results: results }
      end

      # GET /api/v1/knowledge/navigate?module=leads&feature=create
      # Used by the "Take me there" button — deterministic route/selector lookup.
      def navigate
        mod = Knowledge::Module.active.find_by(key: params[:module])
        return render json: { error: 'module not found' }, status: :not_found unless mod

        feature = params[:feature].present? ? mod.features.find_by(key: params[:feature]) : nil

        render json: {
          module:   mod.key,
          feature:  feature&.key,
          route:    feature&.route.presence || mod.route,
          selector: feature&.ui_selector,
          label:    feature&.name || mod.name
        }
      end

      # GET /api/v1/knowledge/articles/:slug
      def article
        article = Knowledge::Article.published.find_by(slug: params[:slug])
        return render json: { error: 'article not found' }, status: :not_found unless article

        render json: article_payload(article, include_body: true)
      end

      # GET /api/v1/knowledge/articles?module=leads
      def articles
        scope = Knowledge::Article.published.ordered
        scope = scope.joins(:knowledge_module).where(knowledge_modules: { key: params[:module] }) if params[:module].present?
        scope = scope.of_type(params[:article_type]) if params[:article_type].present?

        render json: { articles: scope.limit(50).map { |a| article_payload(a) } }
      end

      # POST /api/v1/knowledge/record_search
      # body: { query: '...', result: { slug: 'x' | route: '/y' | tour_id: 3 } }
      #
      # Fired when a user clicks through a SmartSearch result. The search row
      # itself is written by SmartSearchService on every search; this endpoint
      # just updates action_taken on the most recent row for this user + query.
      def record_search
        record = Knowledge::Search
                 .where(user_id: current_user.id, query: params[:query].to_s)
                 .order(created_at: :desc)
                 .first

        action = extract_action(params[:result])
        if record && action
          record.update_columns(action_taken: action)
          render json: { ok: true, updated: true }
        else
          Knowledge::Search.create!(
            user_id:      current_user.id,
            query:        params[:query].to_s,
            action_taken: action,
            result_count: 1
          )
          render json: { ok: true, created: true }
        end
      end

      private

      def article_payload(article, include_body: false)
        payload = {
          id:           article.id,
          slug:         article.slug,
          title:        article.title,
          excerpt:      article.excerpt,
          article_type: article.article_type,
          module:       article.knowledge_module&.key,
          feature:      article.knowledge_feature&.key,
          updated_at:   article.updated_at
        }
        payload.merge!(content: article.content, content_html: article.content_html) if include_body
        payload
      end

      def extract_action(result)
        return nil unless result.is_a?(ActionController::Parameters) || result.is_a?(Hash)
        r = result.to_unsafe_h rescue result
        %w[slug route tour_id].each { |k| return "clicked:#{k}=#{r[k]}" if r[k].present? }
        nil
      end
    end
  end
end
