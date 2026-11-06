# frozen_string_literal: true

module Api
  module V1
    # Company Settings, Integrations, Phone System (3CX). Hands an admin the 3CX
    # CRM template with a fresh leads-only key in it, shows the calls 3CX has
    # reported, and disconnects by revoking the key.
    #
    # Platform admins only (works while impersonating): a dealer downloading a new
    # template silently breaks the one already in their 3CX, so we set it up.
    class PhoneSystemController < ApplicationController
      before_action :set_company_scope

      KEY_NAME = '3CX phone system'
      RECENT = 25

      # GET /api/v1/phone-system
      def show
        return unless require_platform_admin!

        key = current_key
        logs = @company.phone_call_logs.recent.includes(:user, :loggable).limit(RECENT)
        render json: {
          connected: key.present?,
          key_preview: key&.key_preview,
          connected_at: key&.created_at,
          last_used_at: key&.last_used_at,
          api_base_url: api_base_url,
          stats: {
            last_30_days: @company.phone_call_logs.where(created_at: 30.days.ago..).count,
            matched_30_days: @company.phone_call_logs.matched.where(created_at: 30.days.ago..).count
          },
          recent_calls: logs.map { |l| log_json(l) }
        }
      end

      # POST /api/v1/phone-system/three-cx-template
      # A new key every time: the old one is revoked so only the template the
      # admin just uploaded keeps working.
      def three_cx_template
        return unless require_platform_admin!

        key = nil
        ApiKey.transaction do
          @company.api_keys.active.where(name: KEY_NAME).find_each(&:revoke!)
          key = @company.api_keys.create!(
            name: KEY_NAME, created_by_user_id: current_user.id,
            permissions: { 'leads' => %w[read write] }, rate_limit: 5000
          )
        end
        xml = PhoneCalls::ThreeCxTemplate.new(
          base_url: api_base_url, api_key: key.key, brand_name: Brand.current(company: @company).name
        ).to_xml
        send_data xml, filename: 'dealertide-3cx-template.xml', type: 'application/xml', disposition: 'attachment'
      end

      # DELETE /api/v1/phone-system/three-cx
      def disconnect
        return unless require_platform_admin!

        count = 0
        @company.api_keys.active.where(name: KEY_NAME).find_each { |k| k.revoke! && count += 1 }
        render json: { ok: true, revoked: count }
      end

      private

      def current_key
        @company.api_keys.active.where(name: KEY_NAME).order(created_at: :desc).first
      end

      # The address 3CX reaches us on. Production sets MCP_PUBLIC_BASE_URL
      # (https://api.dealertide.com); staging falls back to RAILS_API_URL.
      def api_base_url
        (ENV['MCP_PUBLIC_BASE_URL'].presence || ENV['RAILS_API_URL'].presence || request.base_url).chomp('/')
      end

      def log_json(log)
        rec = log.loggable
        name = case rec
               when Account then rec.name
               when nil then nil
               else [rec.first_name, rec.last_name].compact.join(' ').strip
               end
        {
          id: log.id, call_type: log.call_type, direction: log.direction, outcome: log.outcome,
          number: log.number, agent: log.agent, agent_name: log.agent_name,
          user_name: log.user && [log.user.first_name, log.user.last_name].compact.join(' ').strip,
          started_at: log.started_at || log.created_at, duration_seconds: log.duration_seconds,
          record_type: log.loggable_type&.downcase, record_id: log.loggable_id, record_name: name.presence
        }
      end
    end
  end
end
