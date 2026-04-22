# frozen_string_literal: true

module Webhooks
  class FacebookLeadsController < ActionController::API
    skip_before_action :authenticate, raise: false if defined?(authenticate)

    # GET /webhooks/facebook/leads
    # Meta webhook verification handshake
    def verify
      mode      = params['hub.mode']
      token     = params['hub.verify_token']
      challenge = params['hub.challenge']

      if mode == 'subscribe' && token.present? && token == meta_verify_token
        render plain: challenge.to_s, status: :ok
      else
        Rails.logger.warn "[FacebookLeads] Verification failed: mode=#{mode} token=#{token.present?}"
        head :forbidden
      end
    end

    # POST /webhooks/facebook/leads
    def receive
      unless valid_signature?
        Rails.logger.warn "[FacebookLeads] Invalid X-Hub-Signature-256"
        head :forbidden and return
      end

      payload = parse_payload
      Array(payload['entry']).each do |entry|
        page_id = entry['id']
        Array(entry['changes']).each do |change|
          next unless change['field'] == 'leadgen'
          value = change['value'] || {}
          leadgen_id = value['leadgen_id']
          next if leadgen_id.blank?

          ProcessFacebookLeadJob.perform_later(
            page_id:       page_id,
            leadgen_id:    leadgen_id,
            form_id:       value['form_id'],
            ad_id:         value['ad_id'],
            adgroup_id:    value['adgroup_id'],
            created_time:  value['created_time']
          )
        end
      end

      head :ok
    rescue => e
      Rails.logger.error "[FacebookLeads] receive error: #{e.class}: #{e.message}"
      head :ok
    end

    private

    def meta_verify_token
      Rails.application.credentials.dig(:meta, :webhook_verify_token) ||
        ENV['META_WEBHOOK_VERIFY_TOKEN']
    end

    def meta_app_secret
      Rails.application.credentials.dig(:meta, :app_secret) || ENV['META_APP_SECRET']
    end

    def raw_body
      @raw_body ||= request.raw_post
    end

    def parse_payload
      @parsed_payload ||= JSON.parse(raw_body.presence || '{}')
    rescue JSON::ParserError
      {}
    end

    def valid_signature?
      return false if meta_app_secret.blank?

      header = request.headers['X-Hub-Signature-256'].to_s
      return false unless header.start_with?('sha256=')

      provided = header.split('=', 2).last.to_s
      expected = OpenSSL::HMAC.hexdigest('sha256', meta_app_secret, raw_body)

      ActiveSupport::SecurityUtils.secure_compare(expected, provided)
    end
  end
end
