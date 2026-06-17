require 'net/http'
require 'uri'
require 'json'

module WorkflowEngine
  module StepExecutors
    class ClassifyReply < Base
      ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages'.freeze
      MODEL = 'claude-sonnet-4-6'.freeze

      def call
        cfg = @step['config'] || {}
        categories = Array(cfg['categories'])
        dotted_path = cfg['write_to_variable']
        body_text = @run.variables.dig('reply', 'body')

        if body_text.blank?
          return { status: 'skipped', output: { reason: 'no_reply_body' }, next_step_id: next_step_from_edges, error: {} }
        end

        api_key = Rails.application.credentials.dig(:anthropic, :api_key)
        if api_key.blank?
          return { status: 'skipped', output: { reason: 'ai_not_configured' }, next_step_id: next_step_from_edges, error: {} }
        end

        user_message = "Classify this reply into ONE of these categories: #{categories.join(', ')}\n\nReply text:\n#{body_text}"
        system_message = 'Respond with ONLY a JSON object: {"value": "<category>", "reason": "..."}'

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

        if dotted_path.present? && value
          merged = deep_set(@run.variables.deep_dup, dotted_path, value)
          @run.update!(variables: merged)
        end

        {
          status: 'success',
          output: { value: value, reason: reason, model: MODEL },
          next_step_id: next_step_from_edges,
          error: {}
        }
      rescue => e
        Rails.logger.error "[ClassifyReply] error: #{e.class}: #{e.message}"
        { status: 'failed', output: {}, error: { message: e.message } }
      end

      private

      def deep_set(hash, dotted, value)
        keys = dotted.to_s.split('.')
        return hash if keys.empty?
        cursor = hash
        keys[0..-2].each do |k|
          cursor[k] = {} unless cursor[k].is_a?(Hash)
          cursor = cursor[k]
        end
        cursor[keys.last] = value
        hash
      end
    end
  end
end
