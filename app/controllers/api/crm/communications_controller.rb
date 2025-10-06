# frozen_string_literal: true
module Api
  module Crm
    class CommunicationsController < ApplicationController
      before_action :set_lead, except: [:create_log]

      # GET /api/crm/leads/:lead_id/communications
      def index
        logs = CommunicationLog.for_lead(@lead.id).recent
        render json: logs.map { |log| comm_log_json(log) }, status: :ok
      end

      # POST /api/crm/leads/:lead_id/communications/email
      # POST /api/crm/leads/:lead_id/communications/send_email
      def send_email
        # Support multiple parameter formats
        email_params = extract_email_params

        log = CommunicationLog.create!(
          lead:       @lead,
          comm_type:  'email',
          direction:  'outbound',
          subject:    email_params[:subject],
          content:    email_params[:content],
          status:     'sent',
          sent_at:    Time.current,
          metadata:   build_email_metadata(email_params)
        )

        render json: { 
          ok: true, 
          success: true,
          id: log.id, 
          provider: 'test',
          communication: comm_log_json(log)
        }, status: :created
      rescue => e
        Rails.logger.error("[CommunicationsController#send_email] Error: #{e.message}")
        render json: { 
          ok: false, 
          success: false,
          error: e.message,
          details: e.backtrace.first(3)
        }, status: :unprocessable_entity
      end

      # POST /api/crm/leads/:lead_id/communications/sms
      # POST /api/crm/leads/:lead_id/communications/send_sms
      def send_sms
        # Support multiple parameter formats
        sms_params = extract_sms_params

        log = CommunicationLog.create!(
          lead:       @lead,
          comm_type:  'sms',
          direction:  'outbound',
          content:    sms_params[:content],
          status:     'sent',
          sent_at:    Time.current,
          metadata:   build_sms_metadata(sms_params)
        )

        render json: { 
          ok: true, 
          success: true,
          id: log.id, 
          provider: 'test',
          communication: comm_log_json(log)
        }, status: :created
      rescue => e
        Rails.logger.error("[CommunicationsController#send_sms] Error: #{e.message}")
        render json: { 
          ok: false, 
          success: false,
          error: e.message,
          details: e.backtrace.first(3)
        }, status: :unprocessable_entity
      end

      # POST /api/crm/leads/:lead_id/communications (generic log creation)
      def create
        log = CommunicationLog.create!(log_params)
        render json: comm_log_json(log), status: :created
      rescue => e
        Rails.logger.error("[CommunicationsController#create] Error: #{e.message}")
        render json: { 
          error: e.message,
          details: e.backtrace.first(3)
        }, status: :unprocessable_entity
      end

      # Alias for backward compatibility
      alias_method :create_log, :create

      private

      def set_lead
        @lead = Lead.find(params[:lead_id])
      rescue ActiveRecord::RecordNotFound => e
        render json: { 
          error: 'Lead not found',
          leadId: params[:lead_id]
        }, status: :not_found
      end

      # Extract email parameters from various possible formats
      def extract_email_params
        # Try nested :email key first
        if params[:email].present?
          email_data = params[:email]
          {
            subject: email_data[:subject],
            content: email_data[:body] || email_data[:html] || email_data[:content],
            to: email_data[:to] || @lead.email,
            template_id: email_data[:template_id] || email_data[:templateId],
            cc: email_data[:cc],
            bcc: email_data[:bcc],
            attachments: email_data[:attachments]
          }
        else
          # Fall back to root-level parameters
          {
            subject: params[:subject],
            content: params[:body] || params[:html] || params[:content],
            to: params[:to] || @lead.email,
            template_id: params[:template_id] || params[:templateId],
            cc: params[:cc],
            bcc: params[:bcc],
            attachments: params[:attachments]
          }
        end
      end

      # Extract SMS parameters from various possible formats
      def extract_sms_params
        # Try nested :sms key first
        if params[:sms].present?
          sms_data = params[:sms]
          {
            content: sms_data[:message] || sms_data[:content] || sms_data[:body],
            to: sms_data[:to] || @lead.phone,
            template_id: sms_data[:template_id] || sms_data[:templateId]
          }
        else
          # Fall back to root-level parameters
          {
            content: params[:message] || params[:content] || params[:body],
            to: params[:to] || @lead.phone,
            template_id: params[:template_id] || params[:templateId]
          }
        end
      end

      # Build email metadata
      def build_email_metadata(email_params)
        {
          provider: 'test',
          template_id: email_params[:template_id],
          to: email_params[:to],
          cc: email_params[:cc],
          bcc: email_params[:bcc],
          has_attachments: email_params[:attachments].present?
        }.compact
      end

      # Build SMS metadata
      def build_sms_metadata(sms_params)
        {
          provider: 'test',
          template_id: sms_params[:template_id],
          to: sms_params[:to],
          character_count: sms_params[:content]&.length
        }.compact
      end

      # Strong parameters for generic log creation
      def log_params
        {
          lead_id:      params[:lead_id] || @lead&.id,
          comm_type:    params[:type] || params[:comm_type] || params[:commType],
          direction:    params[:direction] || 'outbound',
          subject:      params[:subject],
          content:      params[:content] || params[:body] || params[:message],
          status:       params[:status].presence || 'sent',
          sent_at:      parse_time(params[:sent_at] || params[:sentAt]) || Time.current,
          delivered_at: parse_time(params[:delivered_at] || params[:deliveredAt]),
          opened_at:    parse_time(params[:opened_at] || params[:openedAt]),
          clicked_at:   parse_time(params[:clicked_at] || params[:clickedAt]),
          metadata:     extract_metadata
        }.compact
      end

      # Extract metadata from params
      def extract_metadata
        if params[:metadata].present?
          params[:metadata].is_a?(Hash) ? params[:metadata] : {}
        else
          {}
        end
      end

      # Consistent JSON serialization for communication logs
      def comm_log_json(log)
        {
          id:          log.id,
          leadId:      log.lead_id,
          type:        log.comm_type,
          commType:    log.comm_type, # Include both formats for compatibility
          direction:   log.direction,
          subject:     log.subject,
          content:     log.content,
          status:      log.status,
          sentAt:      log.sent_at&.iso8601,
          deliveredAt: log.delivered_at&.iso8601,
          openedAt:    log.opened_at&.iso8601,
          clickedAt:   log.clicked_at&.iso8601,
          metadata:    log.metadata || {},
          createdAt:   log.created_at&.iso8601,
          updatedAt:   log.updated_at&.iso8601
        }.compact
      end

      # Parse time strings safely
      def parse_time(value)
        return nil if value.blank?
        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
