# frozen_string_literal: true

module Catalog
  module PriceBooks
    # One forced tool call to Claude. Extraction always answers through a tool
    # schema, never free text, so every value lands in a known field.
    class ClaudeClient
      class Error < StandardError; end

      API_URL = 'https://api.anthropic.com/v1/messages'
      # Dollars per million tokens for the extraction model (Sonnet 4.6).
      INPUT_USD_PER_MTOK = 3.0
      OUTPUT_USD_PER_MTOK = 15.0

      def self.cost_usd(input_tokens, output_tokens)
        ((input_tokens.to_i * INPUT_USD_PER_MTOK) + (output_tokens.to_i * OUTPUT_USD_PER_MTOK)) / 1_000_000.0
      end
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
          raise Error, readable_error(code, response.body) unless RETRYABLE.include?(code)

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

      # The admin sees this on the file, so say what to do rather than show JSON.
      def readable_error(code, body)
        message = JSON.parse(body.to_s).dig('error', 'message') rescue nil
        if message.to_s.match?(/credit balance/i)
          'The Anthropic account is out of credits. Add credits, then choose Read again.'
        else
          "The AI service refused the request (#{code}): #{(message.presence || body.to_s)[0, 200]}"
        end
      end

      def backoff(attempt)
        Rails.env.test? ? 0 : 15 * (attempt + 1)
      end
    end
  end
end
