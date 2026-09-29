# frozen_string_literal: true

module Catalog
  module PriceBooks
    # One forced tool call to Claude. Extraction always answers through a tool
    # schema, never free text, so every value lands in a known field.
    class ClaudeClient
      class Error < StandardError; end

      API_URL = 'https://api.anthropic.com/v1/messages'
      RETRYABLE = [429, 500, 502, 503, 529].freeze

      # @return [Hash] { input:, stop_reason:, input_tokens:, output_tokens: }
      def self.call(content:, tool:, system:, max_tokens: 32_000)
        new.call(content: content, tool: tool, system: system, max_tokens: max_tokens)
      end

      def call(content:, tool:, system:, max_tokens:)
        api_key = ENV['ANTHROPIC_API_KEY'].presence || Rails.application.credentials.dig(:anthropic, :api_key)
        raise Error, 'Anthropic API key not configured' if api_key.blank?

        body = { model: AiModel.for(:vision), max_tokens: max_tokens, system: system,
                 tools: [tool], tool_choice: { type: 'tool', name: tool[:name] },
                 messages: [{ role: 'user', content: content }] }.to_json

        5.times do |attempt|
          response = post(api_key, body)
          code = response.code.to_i
          if code == 200
            json = JSON.parse(response.body)
            tool_use = Array(json['content']).find { |c| c['type'] == 'tool_use' }
            return { input: tool_use&.dig('input') || {}, stop_reason: json['stop_reason'],
                     input_tokens: json.dig('usage', 'input_tokens').to_i,
                     output_tokens: json.dig('usage', 'output_tokens').to_i }
          end
          raise Error, "Claude API error #{code}: #{response.body.to_s[0, 300]}" unless RETRYABLE.include?(code)

          sleep(backoff(attempt))
        end
        raise Error, 'Claude API kept failing after retries'
      end

      private

      def post(api_key, body)
        uri = URI(API_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        # Non-streaming: a dense order form chunk can take a few minutes to write.
        http.read_timeout = 600
        http.open_timeout = 30
        request = Net::HTTP::Post.new(uri, 'content-type' => 'application/json', 'x-api-key' => api_key,
                                           'anthropic-version' => '2023-06-01')
        request.body = body
        http.request(request)
      end

      def backoff(attempt)
        Rails.env.test? ? 0 : 15 * (attempt + 1)
      end
    end
  end
end
