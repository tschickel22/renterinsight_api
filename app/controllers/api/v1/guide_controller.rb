# frozen_string_literal: true

module Api
  module V1
    # In-app guidance: usage events and the person's own usage summary
    # (backlog E75). Every signed-in user may record and read their own usage;
    # there is nothing to authorize beyond being signed in to a company.
    class GuideController < ApplicationController
      before_action :set_company_scope

      # POST /api/v1/guide/events  { events: [{ kind, feature, route, at }] }
      # Only a person's use of their own company counts. Impersonated sessions
      # and platform admins switched into a dealer are not recorded, so looking
      # around a dealer's account never shows up as that dealer using it.
      def events
        return head(:no_content) if impersonating? || @company.id != current_user.company_id

        recorded = Guide::UsageRecorder.new(user: current_user, company_id: @company.id)
                                       .record(params[:events])
        render json: { recorded: recorded }
      end

      # GET /api/v1/guide/assistant
      # Whether the assistant can answer right now, and the latest thread.
      def assistant_status
        conversation = GuideConversation.where(user_id: current_user.id, company_id: @company.id).order(updated_at: :desc).first
        render json: allowance.merge(conversation_id: conversation&.id, messages: Array(conversation&.messages).last(20))
      end

      # POST /api/v1/guide/assistant  { question, conversation_id?, page? }
      # One question to the help assistant. Counts toward the company's
      # monthly AI allowance, the same pool as Report AI.
      def assistant
        question = params[:question].to_s.strip.first(1_000)
        return render(json: { error: 'Ask a question.' }, status: :bad_request) if question.blank?

        limits = allowance
        return render(json: limits.merge(limited: true)) unless limits[:enabled] && limits[:remaining].positive?

        conversation = find_or_start_conversation
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = Guide::Assistant.new(user: current_user, company: @company)
                                 .ask(question, history: conversation.messages, page: params[:page])

        conversation.append('role' => 'user', 'content' => question, 'at' => Time.current.iso8601)
        conversation.append('role' => 'assistant', 'content' => result.answer, 'at' => Time.current.iso8601,
                            'articles' => result.articles, 'places' => result.places, 'answered' => result.answered)
        conversation.save!
        meter(question, result, started)

        render json: {
          conversation_id: conversation.id, answer: result.answer, articles: result.articles,
          places: result.places, answered: result.answered, remaining: limits[:remaining] - 1
        }
      rescue Guide::ClaudeChat::Error => e
        Rails.logger.error("[Guide::Assistant] #{e.message}")
        AiQueryLog.create(company_id: metered_company_id, user_id: current_user.id, feature: 'help_assistant',
                          question: question, execution_status: 'error', error_message: e.message.first(500))
        render json: { error: 'The assistant is not available right now. Search still works.' }, status: :bad_gateway
      end

      # GET /api/v1/guide/checklist
      # Getting started: the company setup list (for admins) and this person's
      # learning path, each item ticked from real data or real use.
      def checklist
        prefs = Setting.get('User', current_user.id, 'guide_checklist', {}) || {}
        data = Guide::Checklist.new(current_user, @company).to_h(selected_path: prefs['path'])
        render json: data.merge(dismissed: prefs['dismissed'] == true)
      end

      # PATCH /api/v1/guide/checklist  { path?, dismissed? }
      def update_checklist
        prefs = (Setting.get('User', current_user.id, 'guide_checklist', {}) || {}).to_h.deep_stringify_keys
        prefs['path'] = params[:path].to_s if Guide::Checklist::PATHS.key?(params[:path].to_s)
        prefs['dismissed'] = ActiveModel::Type::Boolean.new.cast(params[:dismissed]) if params.key?(:dismissed)
        Setting.set('User', current_user.id, 'guide_checklist', prefs)
        checklist
      end

      # GET /api/v1/guide/tips
      def tips
        render json: { tips: Guide::Tips.new(current_user, @company).to_a }
      end

      # POST /api/v1/guide/tips/dismiss  { key }
      def dismiss_tip
        dismissed = Array(Setting.get('User', current_user.id, 'guide_tips_dismissed', []))
        Setting.set('User', current_user.id, 'guide_tips_dismissed', (dismissed + [params[:key].to_s.first(120)]).uniq.last(200))
        tips
      end

      # GET /api/v1/guide/team
      # For a dealership's admins: how far each person has got with the
      # product. Their own company only.
      def team
        return render(json: { error: 'Admins only' }, status: :forbidden) unless current_user.effective_admin?

        since = 30.days.ago
        users = @company.users.where(status: 'active').order(:first_name).limit(200).to_a
        used = GuideFeatureUsage.where(company_id: @company.id, user_id: users.map(&:id)).group_by(&:user_id)
        recent = GuideEvent.where(company_id: @company.id, occurred_at: since..).group(:user_id).distinct.count(:feature_key)
        render json: {
          people: users.map do |u|
            path = Guide::Checklist.new(u, @company)
            prefs = Setting.get('User', u.id, 'guide_checklist', {}) || {}
            data = path.to_h(selected_path: prefs['path'])
            chosen = data[:paths].find { |p| p[:key] == data[:selected_path] }
            {
              id: u.id, name: [u.first_name, u.last_name].compact.join(' ').presence || u.email,
              last_active_at: u.try(:last_active_at), features_used_30d: recent[u.id].to_i,
              features_ever: Array(used[u.id]).size,
              path: chosen && { name: chosen[:name], done: chosen[:items].count { |i| i[:done] }, total: chosen[:items].size }
            }
          end
        }
      end

      # GET /api/v1/guide/usage
      # What this person has used, most recent first.
      def usage
        rows = GuideFeatureUsage.where(user_id: current_user.id, company_id: @company.id)
                                .order(last_used_at: :desc)
                                .limit(500)
        render json: {
          features: rows.map do |u|
            { feature: u.feature_key, first_used_at: u.first_used_at, last_used_at: u.last_used_at, count: u.use_count }
          end
        }
      end

      private

      def allowance
        limit = AiQueryLog.monthly_limit_for(@company, user: original_user)
        used = AiQueryLog.monthly_used_for(@company)
        { enabled: limit.positive?, limit: limit, remaining: [limit - used, 0].max }
      end

      def find_or_start_conversation
        scope = GuideConversation.where(user_id: current_user.id, company_id: @company.id)
        (params[:conversation_id].present? && scope.find_by(id: params[:conversation_id])) ||
          scope.create!(user_id: current_user.id, company_id: @company.id)
      end

      # An admin trying the assistant while impersonating is platform cost,
      # not the dealer's allowance.
      def metered_company_id
        impersonating? ? nil : @company.id
      end

      def meter(question, result, started)
        AiQueryLog.create!(
          company_id: metered_company_id, user_id: current_user.id, feature: 'help_assistant', module_key: 'help',
          question: question, user_question: question, execution_status: 'success',
          resolved_intent: result.answered ? 'answered' : 'unanswered',
          result_count: result.articles.size + result.places.size,
          input_tokens: result.input_tokens, output_tokens: result.output_tokens,
          cost_cents: (Catalog::PriceBooks::ClaudeClient.cost_usd(result.input_tokens, result.output_tokens) * 100).round,
          response_time_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        )
        # The same list Knowledge admin shows as failed searches: questions
        # the help could not answer are the help to write next.
        Knowledge::Search.create(user_id: current_user.id, query: question.first(500), intent_detected: 'assistant',
                                 result_count: result.answered ? result.articles.size + result.places.size : 0,
                                 action_taken: 'assistant')
      end
    end
  end
end
