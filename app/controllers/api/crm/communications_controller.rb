module Api
  module Crm
    class CommunicationsController < ApplicationController
      # GET /api/crm/leads/:lead_id/communications
      def index
        lead = current_lead
        logs = CommunicationLog.for_lead(lead.id).recent
        render json: logs.map { |log| comm_log_json(log) }
      end

      # GET /api/crm/leads/:lead_id/communications/history
      def history
        lead = current_lead
        logs = CommunicationLog.for_lead(lead.id).recent
        render json: logs.map { |log| comm_log_json(log) }
      end

      # GET /api/crm/leads/:lead_id/communications/settings
      # Minimal stub so FE doesn’t break; expand when you wire real settings
      def settings
        render json: { platform: {}, company: {}, effective: {} }
      end

      # POST /api/crm/leads/:lead_id/communications/send_email
      def send_email
        lead = current_lead
        content_val = pick_content(params)

        log = CommunicationLog.create!(
          lead:       lead,
          comm_type:  'email',
          direction:  'outbound',
          subject:    params[:subject],
          content:    content_val,
          status:     'sent',
          sent_at:    Time.current,
          metadata:   { provider: 'test', template_id: params[:template_id], to: params[:to] }.compact
        )

        # keep the simple ok/payload shape your FE already saw
        render json: { ok: true, id: log.id, provider: 'test' }, status: :created
      rescue => e
        render json: { ok: false, error: e.message }, status: :unprocessable_entity
      end

      # POST /api/crm/leads/:lead_id/communications/send_sms
      def send_sms
        lead = current_lead
        content_val = params[:message] || params[:content] || params[:body] || params[:text] || ''

        log = CommunicationLog.create!(
          lead:       lead,
          comm_type:  'sms',
          direction:  'outbound',
          content:    content_val,
          status:     'sent',
          sent_at:    Time.current,
          metadata:   { provider: 'test', template_id: params[:template_id], to: params[:to] }.compact
        )

        render json: { ok: true, id: log.id, provider: 'test' }, status: :created
      rescue => e
        render json: { ok: false, error: e.message }, status: :unprocessable_entity
      end

      # POST /api/crm/leads/:lead_id/communications/log
      # (routes.rb maps to #log)
      def log
        lead        = current_lead
        content_val = pick_content(params)

        log = CommunicationLog.create!(
          lead:       lead,
          comm_type:  params[:comm_type] || params[:type] || 'email',
          direction:  params[:direction] || 'outbound',
          subject:    params[:subject],
          content:    content_val,
          status:     params[:status] || 'sent',
          sent_at:    params[:sent_at] || Time.current,
          delivered_at: params[:delivered_at],
          opened_at:    params[:opened_at],
          clicked_at:   params[:clicked_at],
          metadata:     params[:metadata] || {}
        )

        render json: comm_log_json(log), status: :created
      rescue => e
        render json: { ok: false, error: e.message }, status: :unprocessable_entity
      end

      private

      def current_lead
        Lead.find(params[:lead_id] || params[:id] || params[:leadId])
      end

      # Prefer explicit “content”; fall back to body/html (what your FE/scripts used)
      def pick_content(p)
        p[:content] || p[:body] || p[:html] || ''
      end

      def comm_log_json(log)
        {
          id:          log.id,
          leadId:      log.lead_id,
          type:        log.comm_type,
          direction:   log.direction,
          subject:     log.subject,
          content:     log.content,
          status:      log.status,
          sentAt:      log.sent_at,
          deliveredAt: log.delivered_at,
          openedAt:    log.opened_at,
          clickedAt:   log.clicked_at,
          metadata:    log.metadata
        }.compact
      end
    end
  end
end
