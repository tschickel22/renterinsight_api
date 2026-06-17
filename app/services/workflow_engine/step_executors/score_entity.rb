require 'net/http'
require 'uri'
require 'json'

module WorkflowEngine
  module StepExecutors
    class ScoreEntity < Base
      ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages'.freeze
      MODEL = 'claude-sonnet-4-6'.freeze

      def call
        cfg = @step['config'] || {}
        score_field = cfg['score_field']
        prompt = cfg['prompt']
        api_key = Rails.application.credentials.dig(:anthropic, :api_key)

        if api_key.blank?
          return { status: 'skipped', output: { reason: 'ai_not_configured' }, next_step_id: next_step_from_edges, error: {} }
        end

        entity = load_entity
        sanitized = sanitize(entity&.attributes || {})
        user_message = "#{prompt}\n\nEntity JSON:\n#{sanitized.to_json}"
        system_message = 'Respond with ONLY a JSON object: {"value": ..., "reason": "..."}'

        body = {
          model: MODEL,
          max_tokens: 200,
          system: system_message,
          messages: [{ role: 'user', content: user_message }]
        }

        uri = URI(ANTHROPIC_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = 30
        req = Net::HTTP::Post.new(uri.request_uri)
        req['x-api-key'] = api_key
        req['anthropic-version'] = '2023-06-01'
        req['content-type'] = 'application/json'
        req.body = body.to_json

        res = with_retries { http.request(req) }
        if res.code.to_i >= 400
          return { status: 'failed', output: {}, error: { message: "anthropic_http_#{res.code}" } }
        end

        parsed = JSON.parse(res.body)
        text = parsed.dig('content', 0, 'text').to_s
        json_match = text[/\{.*\}/m]
        data = JSON.parse(json_match) if json_match
        value = data && data['value']
        reason = data && data['reason']

        if entity && score_field.present? && entity.respond_to?(score_field)
          entity.update_column(score_field, value)
        end

        {
          status: 'success',
          output: { value: value, reason: reason, model: MODEL },
          next_step_id: next_step_from_edges,
          error: {}
        }
      rescue => e
        Rails.logger.error "[ScoreEntity] error: #{e.class}: #{e.message}"
        { status: 'failed', output: {}, error: { message: e.message } }
      end

      private

      def load_entity
        return nil unless @run.entity_type.present? && @run.entity_id.present?
        @run.entity_type.constantize.find_by(id: @run.entity_id)
      rescue
        nil
      end

      def sanitize(attrs)
        attrs.reject do |k, _|
          key = k.to_s.downcase
          key.start_with?('password') || key.start_with?('encrypted') || key == 'ssn' || key.end_with?('_token')
        end
      end
    end
  end
end
