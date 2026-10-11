# frozen_string_literal: true

require 'net/http'

module Guide
  # A Claude Messages call with tools, for the help assistant's short
  # look-things-up-then-answer loop. Returns the parsed response body.
  class ClaudeChat
    class Error < StandardError; end

    API_URL = 'https://api.anthropic.com/v1/messages'
    RETRYABLE = [429, 500, 502, 503, 529].freeze

    def call(system:, messages:, tools:, max_tokens: 2_000, model: AiModel.for(:help))
      api_key = ENV['ANTHROPIC_API_KEY'].presence || Rails.application.credentials.dig(:anthropic, :api_key)
      raise Error, 'Anthropic API key not configured' if api_key.blank?

      body = { model: model, max_tokens: max_tokens, system: system, tools: tools, messages: messages }.to_json
      3.times do |attempt|
        response = post(api_key, body)
        return JSON.parse(response.body) if response.code.to_i == 200
        raise Error, "Claude returned #{response.code}" unless RETRYABLE.include?(response.code.to_i)

        sleep(Rails.env.test? ? 0 : 2 * (attempt + 1))
      end
      raise Error, 'Claude kept failing after retries'
    end

    private

    def post(api_key, body)
      uri = URI(API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 15
      http.read_timeout = 90
      request = Net::HTTP::Post.new(uri, 'content-type' => 'application/json', 'x-api-key' => api_key,
                                         'anthropic-version' => '2023-06-01')
      request.body = body
      http.request(request)
    end
  end
end
