# frozen_string_literal: true

require 'net/http'

module SiteProfiles
  # The one AI call in the scan.
  #
  # Follows the Audiences::AiBuilder convention (call_claude, fence-stripped
  # JSON, AiQueryLog metering) so cost tracking and model selection stay in one
  # place. Everything mechanical — brand colours, vendor detection, link roles —
  # already happened deterministically; this only normalises page prose into
  # semantic sections.
  class ProfileBuilder
    class GenerationError < StandardError; end

    CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'
    MAX_TOKENS = 8_000
    FEATURE = 'site_content_profile'

    def initialize(company:, user: nil)
      @company = company
      @user = user
    end

    # digests: [PageDigest::Digest], brand/links/integrations from the
    # deterministic pass. Returns [profile_hash, warnings, usage].
    def call(digests:, brand: {}, links: {}, integrations: [], contact: {}, source_url: nil)
      started = Time.current
      response = call_claude(
        system_prompt: system_prompt,
        user_message: user_message(digests, brand, source_url),
        model: AiModel.for(:generation),
        max_tokens: MAX_TOKENS
      )

      raw = parse_json(response[:text])
      profile, warnings = ProfileSchema.coerce(raw)

      profile = merge_deterministic(profile, brand:, links:, integrations:, contact:, digests:, source_url:)
      log_usage(response, source_url, started)

      [profile, warnings, response]
    end

    private

    # The deterministic extractors are authoritative — the model's guesses at
    # brand colour or integrations lose to what we actually parsed.
    def merge_deterministic(profile, brand:, links:, integrations:, contact:, digests:, source_url:)
      profile['brand'] = profile['brand'].to_h.merge(brand.to_h.compact) { |_k, ai, det| det.presence || ai }
      # Parsed tel:/mailto: beats anything the model inferred from prose.
      profile['contact'] = profile['contact'].to_h.merge(contact.to_h.compact) { |_k, ai, det| det.presence || ai }
      profile['links'] = links.presence || profile['links']

      # Background images are where dealer sites keep their photography, so
      # seed hero/gallery from them when the model did not pick any.
      candidates = digests.flat_map(&:candidate_hero_images).uniq
      media = profile['media'].to_h
      media['hero_images'] = (Array(media['hero_images']) + candidates).uniq.first(12)
      media['gallery'] = (Array(media['gallery']) + candidates).uniq.first(24)
      profile['media'] = media
      profile['integrations'] = integrations.map { |d| detection_to_h(d) }
      profile['source'] = {
        'url' => source_url,
        'pages_scanned' => digests.map(&:url),
        'warnings' => digests.select(&:likely_client_rendered?).map do |d|
          "#{d.url} appears to render its content with JavaScript; little text was recoverable."
        end
      }
      profile
    end

    def detection_to_h(detection)
      return detection if detection.is_a?(Hash)

      {
        'vendor' => detection.vendor,
        'category' => detection.category,
        'disposition' => detection.disposition,
        'config_key' => detection.config_key,
        'value' => detection.value,
        'url' => detection.url,
        'label' => detection.label
      }.compact
    end

    def system_prompt
      <<~PROMPT
        You extract structured content from a manufactured-housing or RV dealer's
        existing website so it can be rebuilt on a new platform.

        You are given compact digests of several pages: headings, paragraphs,
        image URLs, link text and form fields. Your job is to normalise that into
        reusable content sections.

        #{ProfileSchema.prompt_contract}
      PROMPT
    end

    def user_message(digests, brand, source_url)
      payload = {
        source_url: source_url,
        detected_brand: brand,
        pages: digests.map do |d|
          {
            url: d.url,
            title: d.title,
            meta_description: d.meta_description,
            headings: d.headings,
            paragraphs: d.paragraphs,
            images: d.images&.first(20),
            background_images: d.background_images&.first(12),
            forms: d.forms
          }.compact
        end
      }

      "Extract the content profile from these pages:\n\n#{JSON.pretty_generate(payload)}"
    end

    def parse_json(text)
      cleaned = text.to_s.strip
      cleaned = cleaned.gsub(/\A```(?:json)?\s*/, '').gsub(/\s*```\z/, '')
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      raise GenerationError, "AI returned invalid JSON: #{e.message[0, 200]}"
    end

    def call_claude(system_prompt:, user_message:, model:, max_tokens:)
      api_key = Rails.application.credentials.dig(:anthropic, :api_key) || ENV['ANTHROPIC_API_KEY']
      raise GenerationError, 'Anthropic API key not configured' if api_key.blank?

      uri = URI(CLAUDE_API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 180
      http.open_timeout = 30

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = api_key
      request['anthropic-version'] = '2023-06-01'
      request.body = {
        model: model,
        max_tokens: max_tokens,
        system: system_prompt,
        messages: [{ role: 'user', content: user_message }]
      }.to_json

      response = http.request(request)

      unless response.code.to_s == '200'
        body = begin
          JSON.parse(response.body)
        rescue StandardError
          {}
        end
        raise GenerationError, "Claude API error: #{body.dig('error', 'message') || response.code}"
      end

      result = JSON.parse(response.body)
      {
        text: result['content']&.find { |c| c['type'] == 'text' }&.fetch('text', ''),
        model_version: result['model'],
        input_tokens: result.dig('usage', 'input_tokens'),
        output_tokens: result.dig('usage', 'output_tokens')
      }
    end

    def log_usage(response, source_url, started)
      AiQueryLog.create!(
        company: @company,
        user: @user,
        feature: FEATURE,
        module_key: 'marketing.website',
        question: "Scan #{source_url}",
        generated_params: { source_url: source_url },
        execution_status: 'success',
        input_tokens: response[:input_tokens],
        output_tokens: response[:output_tokens],
        response_time_ms: ((Time.current - started) * 1000).round
      )
    rescue StandardError => e
      Rails.logger.warn("[SiteProfiles::ProfileBuilder] usage logging failed: #{e.message}")
    end
  end
end
