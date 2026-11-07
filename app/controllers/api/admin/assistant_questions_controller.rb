# frozen_string_literal: true

# What buyers ask Quinn AI across every dealer (E96), for DealerTide to learn
# from: which topics come up, what Quinn could not answer, and what dealers
# answered, so common answers can become defaults or help content.
# Cross-tenant on purpose; platform admins only (checks original_user).
class Api::Admin::AssistantQuestionsController < ApplicationController
  before_action :require_platform_admin!

  def index
    scope = AssistantQuestion.includes(:company).order(created_at: :desc)
    scope = scope.where(status: params[:status]) if AssistantQuestion::STATUSES.include?(params[:status])
    scope = scope.where(topic: params[:topic]) if AssistantQuestion::TOPICS.include?(params[:topic])
    scope = scope.where('question ILIKE ?', "%#{params[:q].to_s.strip}%") if params[:q].present?
    since = 90.days.ago
    recent = AssistantQuestion.where('created_at >= ?', since)
    render json: {
      items: scope.limit(200).map do |q|
        { id: q.id, company: q.company&.name, company_id: q.company_id, question: q.question, status: q.status, topic: q.topic,
          reply: q.reply, dealer_answer: q.dealer_answer, created_at: q.created_at }
      end,
      summary: {
        since: since,
        by_status: recent.group(:status).count,
        by_topic: recent.group(:topic).count.transform_keys { |k| k || 'other' }
      }
    }
  end
end
