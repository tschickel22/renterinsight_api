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
        # Platform admins can view draft articles; regular users only see published
        scope = platform_admin? ? Knowledge::Article.all : Knowledge::Article.published
        article = scope.find_by(slug: params[:slug])
        return render json: { error: 'article not found' }, status: :not_found unless article

        render json: article_payload(article, include_body: true)
      end

      # GET /api/v1/knowledge/articles?module=leads
      # Filters:
      #   ?module=leads           — filter by module key
      #   ?article_type=guide     — filter by type
      #   ?published=true|false   — explicit published/draft filter (default: true)
      #   ?published=all          — include both (admin view)
      # Returns: { articles: [...], total: N }
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

      # GET /api/v1/knowledge/categories
      # Returns distinct categories with their modules and active tour counts.
      # "Getting Started" is pinned to the top of the list; everything else
      # is alphabetical.
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
      # Three payload shapes:
      #   rename: { old_name: 'X', new_name: 'Y' }
      #   clear:  { name: 'X', delete: true }  # sets modules' category to nil
      #   move:   { module_key: 'leads', category: 'X' }
      # Gated by require_platform_admin! — this mutates the display grouping
      # for every user in the company.
      def manage_category
        return unless require_platform_admin!

        if params[:reset].present?
          # Reset to defaults
          defaults = {
            'leads' => 'CRM & Sales', 'contacts' => 'CRM & Sales', 'accounts' => 'CRM & Sales', 'deals' => 'CRM & Sales',
            'inventory' => 'Inventory & Operations', 'parts' => 'Inventory & Operations', 'suppliers' => 'Inventory & Operations', 'purchase_orders' => 'Inventory & Operations',
            'invoices' => 'Finance', 'payments' => 'Finance', 'loans' => 'Finance', 'quotes' => 'Finance', 'commissions' => 'Finance',
            'service' => 'Service & Support', 'service_tickets' => 'Service & Support', 'warranty' => 'Service & Support', 'warranty_claims' => 'Service & Support',
            'projects' => 'Projects',
            'agreements' => 'Agreements',
            'brochures' => 'Marketing', 'website_builder' => 'Marketing',
            'calendar' => 'Productivity', 'reports' => 'Productivity', 'workflow_automation' => 'Productivity',
            'users' => 'Administration', 'settings' => 'Administration', 'locations' => 'Administration', 'workflows' => 'Administration',
            'dashboard' => 'Getting Started'
          }
          # Clear all first, then re-assign
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
          count = Knowledge::Module.where(category: params[:old_name])
                                   .update_all(category: params[:new_name])
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
          # Creating a new empty category — assign it to a placeholder uncategorized module
          # or just pick the first unassigned module and give it this category
          name = params[:add_category].to_s.strip
          unassigned = Knowledge::Module.active.where(category: [nil, '']).first
          if unassigned
            unassigned.update_columns(category: name)
            render json: { ok: true, category: name, assigned_module: unassigned.key }
          else
            render json: { ok: true, category: name, note: 'No unassigned modules to attach. Move tours into this category using the move action.' }
          end
        else
          render json: { error: 'Invalid params' }, status: :bad_request
        end
      end

      # POST /api/v1/knowledge/articles
      # Body: { article: { title, slug, excerpt, content, article_type,
      #                    module_key, feature_key, is_published, position } }
      # Platform-admin only.
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
      # Partial update — only the fields you send get touched. Platform-admin only.
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
      # Hard-delete. Platform-admin only.
      def delete_article
        return unless require_platform_admin!

        article = Knowledge::Article.find_by(slug: params[:slug])
        return render json: { error: 'article not found' }, status: :not_found unless article

        article.destroy
        render json: { ok: true, deleted: article.slug }
      end

      # POST /api/v1/knowledge/articles/generate
      # Body: { topic: '...', context: '...', module_key: '...' }
      # Returns a draft article payload (title, slug, excerpt, content). Does
      # NOT save — the admin reviews, edits, and then POSTs to /articles to
      # persist. Platform-admin only.
      def generate_article
        return unless require_platform_admin!

        topic = params[:topic].to_s.strip
        return render json: { error: 'topic is required' }, status: :bad_request if topic.empty?

        context    = params[:context].to_s.strip
        module_key = params[:module_key].to_s.strip
        mod        = Knowledge::Module.find_by(key: module_key) if module_key.present?

        # Build rich context from Knowledge database
        platform_context = build_platform_context(mod, topic)

        system_prompt = <<~PROMPT
          You are a technical writer for Renter Insight, a dealer management system (DMS) for manufactured home and RV dealers.
          Write a clear, practical help article in Markdown format.

          Guidelines:
          - Use ## for section headings (not #)
          - Include step-by-step instructions with numbered lists
          - Be concise but thorough
          - Use professional but friendly tone
          - Include tips, warnings, or notes where helpful using > blockquotes
          - Don't include the title as a heading (it's shown separately)
          - Focus on actionable how-to content
          - When describing navigation, use the EXACT navigation paths, tab names, and button labels from the platform context below
          - Always tell the user exactly where to click: sidebar menu item > tab name > button name
          - Reference real UI elements by their actual names

          #{platform_context}
        PROMPT

        user_prompt = "Write a help article about: #{topic}"
        user_prompt += "\n\nAdditional context from the author: #{context}" if context.present?

        api_key = Rails.application.credentials.dig(:anthropic, :api_key)

        # No key? Return a structured template so the admin can still flesh
        # something out by hand rather than getting a stone wall.
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
            model:      'claude-sonnet-4-6',
            max_tokens: 4000,
            system:     system_prompt,
            messages:   [{ role: 'user', content: user_prompt }]
          }.to_json

          response = http.request(request)

          if response.code == '200'
            result = JSON.parse(response.body)
            generated_content = result.dig('content', 0, 'text').to_s

            title   = topic.split(/[:\-\u2013\u2014]/).first.to_s.strip.titleize
            title   = topic.titleize if title.empty?
            slug    = topic.parameterize
            first_p = generated_content.split("\n\n").find { |p| !p.start_with?('#') && p.strip.length > 20 }
            excerpt = first_p ? first_p.strip[0..200] : "Learn about #{topic.downcase} in Renter Insight."

            render json: {
              title:     title,
              slug:      slug,
              excerpt:   excerpt,
              content:   generated_content,
              generated: true
            }
          else
            Rails.logger.error("[Knowledge] AI generation failed: #{response.code} #{response.body&.slice(0, 500)}")
            render json: { error: 'AI generation failed', details: response.code }, status: :bad_gateway
          end
        rescue StandardError => e
          Rails.logger.error("[Knowledge] AI generation error: #{e.class}: #{e.message}")
          render json: { error: 'AI generation failed', details: e.message }, status: :internal_server_error
        end
      end

      private

      # Fallback article shape when no API key is configured.
      def template_article_response(topic)
        {
          title:     topic.titleize,
          slug:      topic.parameterize,
          excerpt:   "Learn how to #{topic.downcase} in Renter Insight.",
          generated: false,
          note:      'AI generation unavailable - template provided. Add your Anthropic API key to credentials for AI generation.',
          content:   <<~MD
            ## Overview

            [Describe what #{topic} is and why it matters]

            ## Getting Started

            1. Navigate to the relevant module
            2. [Add steps here]

            ## Step-by-Step Guide

            ### Step 1: [First step]

            [Describe the first step]

            ### Step 2: [Second step]

            [Describe the second step]

            ## Tips & Best Practices

            > **Tip:** [Add helpful tips here]

            ## Troubleshooting

            - **Issue:** [Common issue]
              **Fix:** [How to resolve]
          MD
        }
      end

      def article_payload(article, include_body: false)
        payload = {
          id:           article.id,
          slug:         article.slug,
          title:        article.title,
          excerpt:      article.excerpt,
          article_type: article.article_type,
          module:       article.knowledge_module&.key,
          feature:      article.knowledge_feature&.key,
          is_published: article.is_published,
          position:     article.position,
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

      # Non-blocking check — returns true/false without rendering a 403.
      def platform_admin?
        current_user&.role == 'platform_admin' || current_user&.respond_to?(:super_admin?) && current_user.super_admin?
      end

      # Build rich context about the platform's UI structure for AI article generation.
      # Pulls module data, features, navigation paths, related modules, and existing
      # articles so the AI can write accurate step-by-step instructions.
      def build_platform_context(mod, topic)
        parts = []

        # Sidebar navigation map — tells AI the real menu structure
        parts << <<~NAV
          ## Platform Navigation (Sidebar Menu Structure)
          The sidebar has these main sections:
          - **Dashboard** → / (home page with stats tiles, quick actions, recent activity)
          - **CRM & Sales** (expandable)
            - Prospecting → /crm (Leads tab, Nurturing tab, Templates tab, Intake Forms tab, Sources tab)
            - Sales Deals → /deals (Pipeline tab, Deals tab, Analytics tab)
            - Contacts → /contacts
            - Accounts → /accounts
            - Quotes → /quotes
          - **Inventory & Operations** (expandable)
            - Inventory → /inventory (Inventory tab, Land Management tab, Analytics tab)
            - Parts & Supplies → /parts (Parts tab, Purchase Orders, Bins, Suppliers tabs)
          - **Finance & Agreements** (expandable)
            - Invoices → /finance/invoices
            - Payments → /finance/payments
            - Agreements → /agreements
          - **Projects** → /projects
          - **Workflow Automation** → /workflow-automation
          - **Marketing** (expandable)
            - Brochures → /brochures
            - Website Builder → /websites
          - **Service & Support** (expandable)
            - Service Tickets → /service
            - Warranty Claims → /warranty
          - **Company Settings** → /company-settings (tabs: Profile, Users, Locations, Roles & Permissions, Communications, Finance, Integrations, API Keys, Webhooks, Tags, Templates, Territories)
            - Finance tab has: Payment Processing, Tax Settings, Draw Schedule Templates, Commission settings
            - Users tab: Invite users, manage roles, deactivate accounts
            - Integrations tab: QuickBooks, Champion IMS, Zego Payments
        NAV

        if mod
          parts << "## Current Module: #{mod.name}"
          parts << "Route: #{mod.route}"
          parts << "Description: #{mod.description}" if mod.description.present?
          parts << "Category: #{mod.category}" if mod.category.present?

          # Navigation path for this module
          nav_path = derive_navigation_path(mod)
          parts << "Navigation: #{nav_path}" if nav_path.present?

          # Features (actions available in this module)
          features = mod.features.order(:key).map { |f| "- #{f.name} (#{f.key})#{f.route.present? ? " at #{f.route}" : ''}" }
          if features.any?
            parts << "\nAvailable actions in #{mod.name}:"
            parts.concat(features)
          end

          # Related modules (same category)
          if mod.category.present?
            related = Knowledge::Module.active.where(category: mod.category).where.not(id: mod.id).pluck(:name, :route)
            if related.any?
              parts << "\nRelated modules in #{mod.category}:"
              related.each { |name, route| parts << "- #{name} → #{route}" }
            end
          end

          # Existing articles for this module (so AI doesn't duplicate)
          existing = Knowledge::Article.published
                                       .where(knowledge_module_id: mod.id)
                                       .pluck(:title, :excerpt)
          if existing.any?
            parts << "\nExisting articles for #{mod.name} (don't duplicate these):"
            existing.each { |title, excerpt| parts << "- #{title}: #{excerpt}" }
          end
        end

        # Search for related modules based on topic keywords
        unless mod
          topic_words = topic.downcase.split(/\s+/) - %w[how to use the a an in for on with and of]
          matched_modules = Knowledge::Module.active.where(
            topic_words.map { |w| "LOWER(name) LIKE ?" }.join(' OR '),
            *topic_words.map { |w| "%#{w}%" }
          ).limit(5)

          if matched_modules.any?
            parts << "\n## Modules that may be related to this topic:"
            matched_modules.each do |m|
              parts << "- #{m.name} (#{m.key}) → #{m.route}"
              nav = derive_navigation_path(m)
              parts << "  Navigation: #{nav}" if nav.present?
            end
          end
        end

        parts.join("\n")
      end

      # Derive the human-readable navigation path for a module based on its route
      def derive_navigation_path(mod)
        route = mod.route.to_s
        case route
        when /^\/company-settings/
          tab = route.match(/tab=(\w+)/)&.captures&.first
          tab_name = tab ? tab.titleize.gsub('_', ' ') : 'Profile'
          "Sidebar → Company Settings → #{tab_name} tab"
        when /^\/finance\//
          sub = route.split('/').last&.titleize
          "Sidebar → Finance & Agreements → #{sub}"
        when /^\/crm/
          "Sidebar → CRM & Sales → Prospecting"
        when /^\/deals/
          "Sidebar → CRM & Sales → Sales Deals"
        when /^\/contacts/
          "Sidebar → CRM & Sales → Contacts"
        when /^\/accounts/
          "Sidebar → CRM & Sales → Accounts"
        when /^\/quotes/
          "Sidebar → CRM & Sales → Quotes"
        when /^\/inventory/
          "Sidebar → Inventory & Operations → Inventory"
        when /^\/parts/
          "Sidebar → Inventory & Operations → Parts & Supplies"
        when /^\/suppliers/
          "Sidebar → Inventory & Operations → Parts & Supplies → Suppliers tab"
        when /^\/projects/
          "Sidebar → Projects"
        when /^\/agreements/
          "Sidebar → Finance & Agreements → Agreements"
        when /^\/service/
          "Sidebar → Service & Support → Service Tickets"
        when /^\/warranty/
          "Sidebar → Service & Support → Warranty Claims"
        when /^\/brochures/
          "Sidebar → Marketing → Brochures"
        when /^\/websites/
          "Sidebar → Marketing → Website Builder"
        when /^\/workflow-automation/
          "Sidebar → Workflow Automation"
        when /^\/commissions/
          "Sidebar → Commissions"
        when /^\/reports/
          "Sidebar → Reports"
        when /^\/calendar/
          "Sidebar → Calendar"
        when '/'
          "Dashboard (home page)"
        else
          nil
        end
      end
    end
  end
end
