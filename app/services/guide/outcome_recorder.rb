# frozen_string_literal: true

module Guide
  # What happens after the help assistant answers, the same from both places
  # it is asked (E118): the Help panel (Api::V1::GuideController) and the
  # sparkle's how-to questions (Api::V1::ReportAiController#help_answer).
  #
  # - no_help: a gap in the help (Knowledge::Search with result_count 0, which
  #   Guide::Gaps lists). Nothing else is a gap: a clarifying question, a
  #   feature we lack or a change request is not missing documentation.
  # - looks_wrong, needs_support: a GuideFlag, emailed to support now, since
  #   the person was told someone will follow up.
  # - not_offered: a GuideFlag feature request, read in bulk.
  class OutcomeRecorder
    FLAG_KINDS = { 'looks_wrong' => 'looks_wrong', 'needs_support' => 'request', 'not_offered' => 'feature_request' }.freeze

    # notify: false when a platform admin is trying it while impersonating;
    # the flag is kept, support is not emailed.
    def self.record!(result:, question:, user:, company_id:, source:, page: nil, conversation: nil, notify: true)
      new(result, question, user, company_id, source, page, conversation, notify).record!
    end

    def initialize(result, question, user, company_id, source, page, conversation, notify)
      @notify = notify
      @result = result
      @question = question.to_s
      @user = user
      @company_id = company_id
      @source = source
      @page = page
      @conversation = conversation
    end

    def record!
      log_search
      flag!
    rescue StandardError => e
      Rails.logger.error("[Guide::OutcomeRecorder] #{e.class} #{e.message}")
      nil
    end

    private

    def log_search
      Knowledge::Search.create(user_id: @user&.id, query: @question.first(500), intent_detected: 'assistant',
                               result_count: @result.outcome == 'no_help' ? 0 : [@result.articles.size + @result.places.size, 1].max,
                               action_taken: 'assistant')
    end

    def flag!
      kind = FLAG_KINDS[@result.outcome]
      return unless kind

      flag = GuideFlag.create!(
        company_id: @company_id, user_id: @user&.id, guide_conversation_id: @conversation&.id, kind: kind,
        question: @question, page: @page, source: @source, assistant_reason: @result.assistant_reason,
        answer_shown: @result.answer, tool_trace: Array(@result.trace)
      )
      GuideFlagMailer.flagged(flag.id).deliver_later if flag.urgent? && @notify
      flag
    end
  end
end
