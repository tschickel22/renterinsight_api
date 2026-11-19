# frozen_string_literal: true

require 'net/http'

module Outreach
  # One forced tool call to Claude, logged with its cost like the other AI
  # features (backlog E105).
  module AiClient
    API_URL = 'https://api.anthropic.com/v1/messages'
    INPUT_USD_PER_MTOK = 3.0
    OUTPUT_USD_PER_MTOK = 15.0

    class Error < StandardError; end

    module_function

    def call(company:, feature:, system:, user:, tool:, max_tokens: 1200)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = post(model: AiModel.for(:lead_assistant), max_tokens: max_tokens, system: system, tools: [tool],
                      tool_choice: { type: 'tool', name: tool[:name] }, messages: [{ role: 'user', content: user }])
      log(company, feature, response, ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      Array(response['content']).detect { |c| c['type'] == 'tool_use' }&.dig('input') || {}
    end

    def post(body)
      key = Rails.application.credentials.dig(:anthropic, :api_key) || ENV['ANTHROPIC_API_KEY']
      raise Error, 'Anthropic API key not configured' if key.blank?

      uri = URI(API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 60
      http.open_timeout = 10
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = key
      request['anthropic-version'] = '2023-06-01'
      request.body = body.to_json
      response = http.request(request)
      raise Error, "Claude returned #{response.code}" unless response.code.to_s == '200'

      JSON.parse(response.body)
    end

    def log(company, feature, response, ms)
      input = response.dig('usage', 'input_tokens').to_i
      output = response.dig('usage', 'output_tokens').to_i
      AiQueryLog.create!(company_id: company.id, feature: "outreach_#{feature}", action_name: response['model'].to_s.truncate(80),
                         module_key: Outreach::Settings::MODULE_KEY, input_tokens: input, output_tokens: output,
                         response_time_ms: ms, execution_status: 'success',
                         cost_cents: ((input * INPUT_USD_PER_MTOK + output * OUTPUT_USD_PER_MTOK) / 10_000.0).round)
    rescue StandardError => e
      Rails.logger.warn("[Outreach::AiClient] usage log failed: #{e.message}")
    end
  end
end
