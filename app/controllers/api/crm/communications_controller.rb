module Api
  module Crm
    class CommunicationsController < ApplicationController
      def index
        lead = Lead.find(params[:lead_id])
        logs = CommunicationLog.for_lead(lead.id).recent
        render json: logs.map { |log| comm_log_json(log) }
      end

      def send_email
        lead = Lead.find(params[:lead_id])
        log = CommunicationLog.create!(
          lead:       lead,
          comm_type:  'email',
          direction:  'outbound',
          subject:    params[:subject],
          content:    params[:body] || params[:html],
          status:     'sent',
          sent_at:    Time.current,
          metadata:   { provider: 'test', template_id: params[:template_id] }.compact
        )
        render json: { ok: true, id: log.id, provider: 'test' }
      rescue => e
        render json: { ok: false, error: e.message }, status: :unprocessable_entity
      end

      def send_sms
        lead = Lead.find(params[:lead_id])
        log = CommunicationLog.create!(
          lead:       lead,
          comm_type:  'sms',
          direction:  'outbound',
          content:    params[:message],
          status:     'sent',
          sent_at:    Time.current,
          metadata:   { provider: 'test', template_id: params[:template_id], to: params[:to] }.compact
        )
        render json: { ok: true, id: log.id, provider: 'test' }
      rescue => e
        render json: { ok: false, error: e.message }, status: :unprocessable_entity
      end

      def create_log
        log = CommunicationLog.create!(log_params)
        render json: comm_log_json(log), status: :created
      end

      private

      def log_params
        {
          lead_id:     params[:lead_id],
          comm_type:   params[:type],
          direction:   params[:direction],
          subject:     params[:subject],
          content:     params[:content],
          status:      params[:status].presence || 'sent',
          sent_at:     params[:sent_at].presence || Time.current,
          delivered_at: params[:delivered_at],
          opened_at:    params[:opened_at],
          clicked_at:   params[:clicked_at],
          metadata:     params[:metadata] || {}
        }.compact
      end

      def comm_log_json(log)
        {
          id:         log.id,
          leadId:     log.lead_id,
          type:       log.comm_type,
          direction:  log.direction,
          subject:    log.subject,
          content:    log.content,
          status:     log.status,
          sentAt:     log.sent_at,
          deliveredAt: log.delivered_at,
          openedAt:    log.opened_at,
          clickedAt:   log.clicked_at,
          metadata:    log.metadata
        }.compact
      end
    end
  end
end
