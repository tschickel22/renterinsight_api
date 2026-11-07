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

  # Per dealer, this month (or ?month=YYYY-MM): Quinn's model calls, tokens
  # and cost from ai_query_logs, the texts Quinn sent and received from
  # sms_usage_logs, its emails, and its website chat answers.
  def usage
    month = (Date.strptime(params[:month].to_s, '%Y-%m') rescue Date.current.beginning_of_month)
    range = month.beginning_of_month.beginning_of_day..month.end_of_month.end_of_day
    ai = AiQueryLog.where(created_at: range).where("feature LIKE 'quinn\\_%'")
                   .group(:company_id).pluck(:company_id, Arel.sql('COUNT(*)'), Arel.sql('SUM(input_tokens)'),
                                             Arel.sql('SUM(output_tokens)'), Arel.sql('SUM(cost_cents)'))
    texts = SmsUsageLog.where(created_at: range, source: 'assistant', direction: 'outbound').group(:company_id).sum(:message_count)
    replies_in = Communication.where(created_at: range, direction: 'inbound', channel: 'sms')
                              .where(conversation_id: Conversation.where(assistant_enabled: true).select(:id)).group(:company_id).count
    emails = Communication.where(created_at: range, channel: 'email', direction: 'outbound')
                          .where("metadata->>'sent_by' = 'assistant'").group(:company_id).count
    chats = ChatMessage.where(created_at: range, direction: 'outbound', sent_by: 'assistant').group(:company_id).count
    ids = (ai.map(&:first) + texts.keys + emails.keys + chats.keys).compact.uniq
    names = Company.where(id: ids).pluck(:id, :name).to_h
    rows = ids.map do |id|
      calls = ai.find { |r| r[0] == id } || [id, 0, 0, 0, 0]
      { company_id: id, company: names[id], ai_calls: calls[1].to_i, input_tokens: calls[2].to_i, output_tokens: calls[3].to_i,
        ai_cost_cents: calls[4].to_i, texts_sent: texts[id].to_i, texts_received: replies_in[id].to_i,
        emails_sent: emails[id].to_i, chat_answers: chats[id].to_i,
        text_cost_cents: (texts[id].to_i * SmsUsageLog::OUTBOUND_COST * 100).round }
    end.sort_by { |r| -(r[:ai_cost_cents] + r[:text_cost_cents]) }
    render json: { month: month.strftime('%Y-%m'), items: rows }
  end
end
