# frozen_string_literal: true

module Api
  module V1
    class KnowledgeController < ApplicationController
      before_action :authenticate_user!

      # GET/POST /api/v1/knowledge/search
      # Accepts: ?q=... or ?query=... or body { query: "..." }
      def search
        query = (params[:q] || params[:query]).to_s.strip
        return render json: { error: 'query is required' }, status: :bad_request if query.empty?

        results = Knowledge::SmartSearchService.new(query, user: current_user).search
        render json: { query: query, results: results }
      end

      # GET /api/v1/knowledge/navigate?module=leads&feature=create
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
        scope = platform_admin? ? Knowledge::Article.all : Knowledge::Article.published
        article = scope.find_by(slug: params[:slug])
        return render json: { error: 'article not found' }, status: :not_found unless article

        render json: article_payload(article, include_body: true)
      end

      # GET /api/v1/knowledge/articles?module=leads
      def articles
        scope = case params[:published].to_s
                when 'false' then Knowledge::Article.where(is_published: false)
                when 'all'   then Knowledge::Article.all
                else              Knowledge::Article.published
                end
        scope = scope.ordered
        scope = scope.joins(:knowledge_module).where(knowledge_modules: { key: params[:module] }) if params[:module].present?
        scope = scope.of_type(params[:article_type]) if params[:article_type].present?

        total = scope.count
        render json: {
          articles: scope.limit(50).map { |a| article_payload(a) },
          total:    total
        }
      end

      # POST /api/v1/knowledge/record_search
      def record_search
        record = Knowledge::Search
                 .where(user_id: current_user.id, query: (params[:q] || params[:query]).to_s)
                 .order(created_at: :desc)
                 .first

        action = extract_action(params[:result])
        if record && action
          record.update_columns(action_taken: action)
          render json: { ok: true, updated: true }
        else
          Knowledge::Search.create!(
            user_id:      current_user.id,
            query:        (params[:q] || params[:query]).to_s,
            action_taken: action,
            result_count: 1
          )
          render json: { ok: true, created: true }
        end
      end

      # GET /api/v1/knowledge/categories
      def categories
        modules = Knowledge::Module.active
                                   .where.not(category: [nil, ''])
                                   .order(:category, :name)

        grouped = modules.group_by(&:category).map do |category, mods|
          tour_count = Tour.active.where(knowledge_module_id: mods.map(&:id)).count
          {
            name:       category,
            modules:    mods.map { |m| { key: m.key, name: m.name } },
            tour_count: tour_count
          }
        end

        render json: {
          categories: grouped.sort_by { |c| c[:name] == 'Getting Started' ? '!' : c[:name] }
        }
      end

      # POST /api/v1/knowledge/categories
      def manage_category
        return unless require_platform_admin!

        if params[:reset].present?
          defaults = {
            'leads' => 'CRM & Sales', 'contacts' => 'CRM & Sales', 'accounts' => 'CRM & Sales', 'deals' => 'CRM & Sales',
            'inventory' => 'Inventory & Operations', 'parts' => 'Inventory & Operations', 'suppliers' => 'Inventory & Operations', 'purchase_orders' => 'Inventory & Operations',
            'invoices' => 'Finance', 'payments' => 'Finance', 'loans' => 'Finance', 'quotes' => 'Finance', 'commissions' => 'Finance',
            'service' => 'Service & Support', 'service_tickets' => 'Service & Support', 'warranty' => 'Service & Support', 'warranty_claims' => 'Service & Support',
            'projects' => 'Projects', 'agreements' => 'Agreements',
            'brochures' => 'Marketing', 'website_builder' => 'Marketing',
            'calendar' => 'Productivity', 'reports' => 'Productivity', 'workflow_automation' => 'Productivity',
            'users' => 'Administration', 'settings' => 'Administration', 'locations' => 'Administration', 'workflows' => 'Administration',
            'dashboard' => 'Getting Started'
          }
          Knowledge::Module.active.update_all(category: nil)
          updated = 0
          defaults.each do |key, cat|
            m = Knowledge::Module.find_by(key: key)
            next unless m
            m.update_columns(category: cat)
            updated += 1
          end
          render json: { ok: true, reset: updated }
        elsif params[:old_name].present? && params[:new_name].present?
          count = Knowledge::Module.where(category: params[:old_name]).update_all(category: params[:new_name])
          render json: { ok: true, renamed: count }
        elsif params[:name].present? && params[:delete].present?
          count = Knowledge::Module.where(category: params[:name]).update_all(category: nil)
          render json: { ok: true, cleared: count }
        elsif params[:module_key].present? && params[:category].present?
          mod = Knowledge::Module.find_by(key: params[:module_key])
          if mod
            mod.update_columns(category: params[:category])
            render json: { ok: true, module: mod.key, category: params[:category] }
          else
            render json: { error: 'Module not found' }, status: :not_found
          end
        elsif params[:add_category].present?
          name = params[:add_category].to_s.strip
          unassigned = Knowledge::Module.active.where(category: [nil, '']).first
          if unassigned
            unassigned.update_columns(category: name)
            render json: { ok: true, category: name, assigned_module: unassigned.key }
          else
            render json: { ok: true, category: name, note: 'No unassigned modules to attach.' }
          end
        else
          render json: { error: 'Invalid params' }, status: :bad_request
        end
      end

      # POST /api/v1/knowledge/articles
      def create_article
        return unless require_platform_admin!

        mod     = Knowledge::Module.find_by(key: params.dig(:article, :module_key))
        feature = mod&.features&.find_by(key: params.dig(:article, :feature_key)) if params.dig(:article, :feature_key).present?

        article = Knowledge::Article.new(
          title:             params.dig(:article, :title),
          slug:              params.dig(:article, :slug).presence || params.dig(:article, :title).to_s.parameterize,
          excerpt:           params.dig(:article, :excerpt),
          content:           params.dig(:article, :content),
          article_type:      params.dig(:article, :article_type) || 'guide',
          knowledge_module:  mod,
          knowledge_feature: feature,
          is_published:      params.dig(:article, :is_published) != false,
          position:          params.dig(:article, :position) || 0
        )

        if article.save
          render json: article_payload(article, include_body: true), status: :created
        else
          render json: { errors: article.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/knowledge/articles/:slug
      def update_article
        return unless require_platform_admin!

        article = Knowledge::Article.find_by(slug: params[:slug])
        return render json: { error: 'article not found' }, status: :not_found unless article

        attrs = {}
        attrs[:title]        = params.dig(:article, :title)        if params.dig(:article, :title).present?
        attrs[:slug]         = params.dig(:article, :slug)         if params.dig(:article, :slug).present?
        attrs[:excerpt]      = params.dig(:article, :excerpt)      if params.dig(:article, :excerpt).present?
        attrs[:content]      = params.dig(:article, :content)      if params.dig(:article, :content)
        attrs[:article_type] = params.dig(:article, :article_type) if params.dig(:article, :article_type).present?
        attrs[:is_published] = params.dig(:article, :is_published) unless params.dig(:article, :is_published).nil?
        attrs[:position]     = params.dig(:article, :position)     if params.dig(:article, :position).present?

        if params.dig(:article, :module_key).present?
          new_mod = Knowledge::Module.find_by(key: params.dig(:article, :module_key))
          attrs[:knowledge_module] = new_mod if new_mod
        end
        if params.dig(:article, :feature_key).present?
          scope = (attrs[:knowledge_module] || article.knowledge_module)
          feature = scope&.features&.find_by(key: params.dig(:article, :feature_key))
          attrs[:knowledge_feature] = feature if feature
        end

        if article.update(attrs)
          render json: article_payload(article.reload, include_body: true)
        else
          render json: { errors: article.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/knowledge/articles/:slug
      def delete_article
        return unless require_platform_admin!
        article = Knowledge::Article.find_by(slug: params[:slug])
        return render json: { error: 'article not found' }, status: :not_found unless article
        article.destroy
        render json: { ok: true, deleted: article.slug }
      end

      # POST /api/v1/knowledge/articles/generate
      def generate_article
        return unless require_platform_admin!

        topic = params[:topic].to_s.strip
        return render json: { error: 'topic is required' }, status: :bad_request if topic.empty?

        context    = params[:context].to_s.strip
        module_key = params[:module_key].to_s.strip
        mod        = Knowledge::Module.find_by(key: module_key) if module_key.present?

        platform_context = build_platform_context(mod, topic)

        system_prompt = <<~PROMPT
          You are a technical writer for #{Brand.current.name}, a dealer management system (DMS) for manufactured home and RV dealers.
          Write a clear, practical help article in Markdown format.
          Guidelines:
          - Use ## for section headings (not #)
          - Include step-by-step instructions with numbered lists
          - Be concise but thorough
          - Use professional but friendly tone
          - Include tips, warnings, or notes where helpful using > blockquotes
          - Don't include the title as a heading (it's shown separately)
          - Focus on actionable how-to content
          - When describing navigation, use the EXACT navigation paths from the platform context below
          #{platform_context}
        PROMPT

        user_prompt = "Write a help article about: #{topic}"
        user_prompt += "\n\nAdditional context: #{context}" if context.present?

        # Match the key resolution used everywhere else in the app (e.g.
        # ReportAiController): prefer the ENV var, fall back to credentials.
        # Production sets ANTHROPIC_API_KEY as an env var, not in credentials —
        # reading credentials alone made this silently fall back to the stub.
        api_key = ENV['ANTHROPIC_API_KEY'] || Rails.application.credentials.dig(:anthropic, :api_key)

        if api_key.blank?
          render json: template_article_response(topic)
          return
        end

        begin
          require 'net/http'
          require 'json'

          uri  = URI('https://api.anthropic.com/v1/messages')
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl      = true
          http.read_timeout = 60

          request = Net::HTTP::Post.new(uri)
          request['Content-Type']      = 'application/json'
          request['x-api-key']         = api_key
          request['anthropic-version'] = '2023-06-01'
          request.body = {
            model: AiModel.for(:generation), max_tokens: 4000,
            system: system_prompt,
            messages: [{ role: 'user', content: user_prompt }]
          }.to_json

          response = http.request(request)

          if response.code == '200'
            result = JSON.parse(response.body)
            generated_content = result.dig('content', 0, 'text').to_s
            title   = topic.split(/[:\-\u2013\u2014]/).first.to_s.strip.titleize
            title   = topic.titleize if title.empty?
            slug    = topic.parameterize
            first_p = generated_content.split("\n\n").find { |p| !p.start_with?('#') && p.strip.length > 20 }
            excerpt = first_p ? first_p.strip[0..200] : "Learn about #{topic.downcase} in #{Brand.current.name}."

            render json: { title: title, slug: slug, excerpt: excerpt, content: generated_content, generated: true }
          else
            Rails.logger.error("[Knowledge] AI generation failed: #{response.code}")
            render json: { error: 'AI generation failed', details: response.code }, status: :bad_gateway
          end
        rescue StandardError => e
          Rails.logger.error("[Knowledge] AI generation error: #{e.class}: #{e.message}")
          render json: { error: 'AI generation failed', details: e.message }, status: :internal_server_error
        end
      end

      private

      def template_article_response(topic)
        {
          title: topic.titleize, slug: topic.parameterize,
          excerpt: "Learn how to #{topic.downcase} in #{Brand.current.name}.",
          generated: false,
          note: 'AI generation unavailable - template provided.',
          content: "## Overview\n\n[Describe what #{topic} is]\n\n## Getting Started\n\n1. Navigate to the relevant module\n2. [Add steps]\n\n## Tips\n\n> **Tip:** [Add tips here]"
        }
      end

      def article_payload(article, include_body: false)
        payload = {
          id: article.id, slug: article.slug, title: article.title,
          excerpt: article.excerpt, article_type: article.article_type,
          module: article.knowledge_module&.key, feature: article.knowledge_feature&.key,
          is_published: article.is_published, position: article.position,
          updated_at: article.updated_at
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

      def platform_admin?
        current_user&.role == 'platform_admin' || current_user&.respond_to?(:super_admin?) && current_user.super_admin?
      end

      def build_platform_context(mod, topic)
        parts = []
        parts << "## Platform Navigation\nSidebar: Dashboard, CRM & Sales (Leads/Deals/Contacts/Accounts/Quotes), Inventory, Parts, Finance, Agreements, Projects, Service, Warranty, Marketing, Settings"

        if mod
          parts << "## Current Module: #{mod.name}\nRoute: #{mod.route}"
          parts << "Description: #{mod.description}" if mod.description.present?
          features = mod.features.order(:key).map { |f| "- #{f.name} (#{f.key})#{f.route.present? ? " at #{f.route}" : ''}" }
          parts.concat(features) if features.any?
        end

        parts.join("\n")
      end
    end
  end
end
