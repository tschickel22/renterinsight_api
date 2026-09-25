# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module SocialBlog
  # Writes the blog version of a social post: a longer piece on the same
  # subject, in HTML, with its own title and search fields.
  #
  # The social generator is capped at 800 tokens and a caption of about 250
  # words, which is too short for a blog post, so this makes its own call. It
  # reads the same company profile so both sound like the same business.
  class Generator
    class Error < StandardError; end

    MAX_TOKENS = 3000
    VERSION    = 'sbg-2026-09-25'

    # Tags the post body may use. Anything else the model returns is stripped
    # before it is shown or saved.
    ALLOWED_TAGS       = %w[p h2 h3 ul ol li strong em a blockquote br].freeze
    ALLOWED_ATTRIBUTES = %w[href].freeze

    # Also used on text a person edited, which reaches the public site as-is.
    def self.sanitize_html(html)
      Rails::HTML5::SafeListSanitizer.new.sanitize(html.to_s, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES).strip
    end

    def self.generate(company:, caption:, headline: nil, description: nil, hashtags: [], intent_category: nil, vehicle: nil)
      new(company: company, caption: caption, headline: headline, description: description,
          hashtags: hashtags, intent_category: intent_category, vehicle: vehicle).generate
    end

    def initialize(company:, caption:, headline:, description:, hashtags:, intent_category:, vehicle:)
      @company         = company
      @caption         = caption.to_s
      @headline        = headline.to_s
      @description     = description.to_s
      @hashtags        = Array(hashtags).map { |h| h.to_s.delete('#').strip }.reject(&:blank?)
      @intent_category = intent_category.to_s
      @vehicle         = vehicle
    end

    def generate
      raise Error, 'Write the social post first. The blog version is written from it.' if @caption.strip.blank?

      api_key = Rails.application.credentials.dig(:anthropic, :api_key) || ENV['ANTHROPIC_API_KEY']
      raise Error, 'Anthropic API key is not configured' if api_key.blank?

      parsed = parse(call_claude(api_key))
      title  = parsed['title'].to_s.strip
      body   = sanitize(parsed['content_html'].to_s)
      raise Error, 'The blog version came back empty. Try again.' if title.blank? || body.blank?

      {
        title:                 title,
        slug:                  (parsed['slug'].presence || title).to_s.parameterize.first(80),
        excerpt:               clip(parsed['excerpt'], 300),
        content:               body,
        seo_title:             clip(parsed['seo_title'], 70).presence || clip(title, 70),
        seo_description:       clip(parsed['seo_description'], 160),
        tags:                  Array(parsed['tags']).map(&:to_s).map(&:strip).reject(&:blank?).first(8),
        ai_generation_version: VERSION
      }
    end

    private

    def system_prompt
      family = SocialPostIntentCatalog.for_company(@company).family
      writer = case family
               when :dealer then 'You write blog posts for a manufactured housing and RV dealership.'
               when :saas   then 'You write blog posts for a B2B software company.'
               else              'You write blog posts for a local service business.'
               end

      <<~PROMPT
        #{writer}
        You are given a social media post the business has written. Write the blog version of it:
        the same subject and the same facts, expanded into something worth reading on its own.

        Rules:
        - 500 to 900 words.
        - Speak as the business ("we", "our").
        - Use only facts from the social post and the business profile. Do not invent prices,
          dates, statistics, names, quotes or offers.
        - Structure: a short opening paragraph, then two to four sections with <h2> headings,
          then a closing paragraph with one clear next step.
        - HTML only, using just these tags: #{ALLOWED_TAGS.join(', ')}. No <h1>, no inline styles,
          no images, no hashtags in the body.
        - Do not use em dashes.
        - The title is plain text, under 70 characters, and not clickbait.

        Return JSON only, with exactly these keys:
        {"title": "", "slug": "", "excerpt": "", "content_html": "", "seo_title": "", "seo_description": "", "tags": []}
        excerpt: one or two sentences, under 300 characters.
        seo_title: under 60 characters. seo_description: under 155 characters.
        tags: three to six short topic tags, no # sign.
      PROMPT
    end

    def user_prompt
      lines = []
      lines << "Business: #{@company.name}"
      location = [@company.try(:city), @company.try(:state)].compact_blank.join(', ')
      lines << "Location: #{location}" if location.present?

      profile = SocialPostGeneratorService.business_profile(@company)
      profile.each { |k, v| lines << "#{k.to_s.humanize}: #{v}" if v.present? }

      if @vehicle
        unit = [@vehicle.try(:year), @vehicle.try(:make), @vehicle.try(:model)].compact.join(' ')
        lines << "Featured unit: #{unit}" if unit.present?
      end

      lines << ''
      lines << "Post type: #{@intent_category.humanize}" if @intent_category.present?
      lines << "Headline: #{@headline}" if @headline.present?
      lines << "Social post:\n#{@caption}"
      lines << "Link description: #{@description}" if @description.present?
      lines << "Hashtags: #{@hashtags.join(', ')}" if @hashtags.any?
      lines << ''
      lines << 'Return JSON only.'
      lines.join("\n")
    end

    def call_claude(api_key)
      uri  = URI('https://api.anthropic.com/v1/messages')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = true
      http.read_timeout = 90
      http.open_timeout = 10

      request = Net::HTTP::Post.new(uri)
      request['Content-Type']      = 'application/json'
      request['x-api-key']         = api_key
      request['anthropic-version'] = '2023-06-01'
      request.body = {
        model:      AiModel.for(:generation),
        max_tokens: MAX_TOKENS,
        system:     system_prompt,
        messages:   [{ role: 'user', content: user_prompt }]
      }.to_json

      response = http.request(request)
      raise Error, "Claude API error (#{response.code}): #{response.body.to_s.truncate(300)}" unless response.code == '200'

      JSON.parse(response.body)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise Error, "Claude timeout: #{e.message}"
    end

    def parse(response)
      text    = response.dig('content', 0, 'text').to_s.strip
      cleaned = text.sub(/\A```(?:json)?\s*/i, '').sub(/\s*```\z/, '').strip
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      raise Error, "Claude returned non-JSON content: #{e.message}"
    end

    # The model sometimes runs past the length it was asked for. Cut at a word,
    # so a search result does not end in half a word.
    def clip(text, limit)
      text.to_s.strip.truncate(limit, separator: ' ', omission: '')
    end

    def sanitize(html)
      self.class.sanitize_html(html)
    end
  end
end
