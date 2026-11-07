# frozen_string_literal: true

module Api
  module Crm
    # Questions buyers asked Quinn AI (E96). The dealer answers the ones it
    # could not, and each answer becomes a FAQ Quinn uses from then on.
    class AssistantQuestionsController < ApplicationController
      before_action :set_company_scope
      before_action :set_question, only: %i[answer dismiss]

      def index
        return unless authorize_action!('company_settings', 'read')

        scope = @company.assistant_questions.order(created_at: :desc)
        scope = params[:status] == 'all' ? scope.where.not(status: 'dismissed') : scope.needing_answer
        render json: {
          items: scope.limit(100).map { |q| json(q) },
          counts: { needing_answer: @company.assistant_questions.needing_answer.count,
                    all: @company.assistant_questions.where.not(status: 'dismissed').count }
        }
      end

      # The dealer's answer, added to Quinn's FAQs.
      def answer
        return unless authorize_action!('company_settings', 'update')

        text = params[:answer].to_s.squish
        question = params[:question].to_s.squish.presence || @question.question
        return render(json: { error: 'Write an answer first' }, status: :unprocessable_entity) if text.blank?

        settings = Assistant::Settings.for(@company)
        faqs = Array(settings['faqs']).reject { |f| f['q'].to_s.casecmp?(question) }
        settings.update!('faqs' => faqs + [{ 'q' => question, 'a' => text }])
        @question.update!(dealer_answer: text, answered_by_user_id: current_user.id, answered_at: Time.current)
        render json: json(@question)
      end

      def dismiss
        return unless authorize_action!('company_settings', 'update')

        @question.update!(status: 'dismissed')
        render json: json(@question)
      end

      private

      def set_question
        @question = @company.assistant_questions.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def json(q)
        { id: q.id, question: q.question, status: q.status, topic: q.topic, reply: q.reply, dealer_answer: q.dealer_answer,
          conversation_id: q.conversation_id, created_at: q.created_at, answered_at: q.answered_at }
      end
    end
  end
end
