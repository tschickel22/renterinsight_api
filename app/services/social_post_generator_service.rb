# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

# AI-powered social post generator for manufactured housing / RV dealerships.
# Returns a hash with caption, headline, description, hashtags, cta_type,
# plus a `generation_context` of the inputs used — so the caller can persist
# it on a SocialPost for traceability.
class SocialPostGeneratorService
  class Error < StandardError; end

  MODEL      = 'claude-sonnet-4-20250514'
  MAX_TOKENS = 800
  VERSION    = 'spg-2026-04-19'

  VALID_INTENTS = %w[
    specific_unit price_drop social_proof education financing
    lifestyle seasonal rep_personal new_arrival aged_inventory
    ad_content
  ].freeze

  class << self
    def generate(company:, intent_category:, post_type:, platform:, vehicle: nil, user: nil, tone: 'friendly', topic_details: nil, intake_form_url: nil)
      unless VALID_INTENTS.include?(intent_category)
        raise Error, "invalid intent_category '#{intent_category}'. Must be one of: #{VALID_INTENTS.join(', ')}"
      end

      api_key = resolve_api_key
      raise Error, 'Anthropic API key is not configured' if api_key.blank?

      ctx = build_context(company: company, vehicle: vehicle, user: user,
                          intent_category: intent_category, post_type: post_type,
                          platform: platform, tone: tone,
                          topic_details: topic_details, intake_form_url: intake_form_url)

      prompt        = build_user_prompt(ctx)
      system_prompt = build_system_prompt(ctx)

      response = call_claude(api_key, system_prompt, prompt)
      parsed   = parse_model_output(response)

      payload = {
        caption:     parsed['caption'],
        headline:    parsed['headline'],
        description: parsed['description'],
        hashtags:    Array(parsed['hashtags']),
        cta_type:    parsed['cta_type'],
        ai_generation_version: VERSION,
        generation_context: ctx,
        usage: {
          input_tokens:  response.dig('usage', 'input_tokens').to_i,
          output_tokens: response.dig('usage', 'output_tokens').to_i
        }
      }

      payload[:ad_settings] = build_ad_settings(company: company, vehicle: vehicle) if intent_category == 'ad_content'
      payload
    end

    private

    def resolve_api_key
      Rails.application.credentials.dig(:anthropic, :api_key) || ENV['ANTHROPIC_API_KEY']
    end

    # ------------------------------------------------------------------
    # Ad settings (for intent_category == 'ad_content')
    # ------------------------------------------------------------------
    def build_ad_settings(company:, vehicle:)
      price = vehicle.try(:sale_price).to_f if vehicle
      budget = recommended_budget(price)
      dealership_city = company&.try(:city).to_s

      {
        recommended_audience: {
          age_min:      25,
          age_max:      65,
          radius_miles: 50,
          interests: [
            'Manufactured homes',
            'Home buying',
            'Real estate',
            'First-time homebuyer',
            'Affordable housing'
          ]
        },
        recommended_budget:    budget,
        recommended_objective: 'lead_generation',
        setup_instructions: [
          'Go to Facebook Ads Manager (business.facebook.com)',
          'Click Create → Choose objective: Lead Generation',
          "Set your daily budget to $#{budget[:daily_min]}-$#{budget[:daily_max]}",
          "Target: Age 25-65, within 50 miles of #{dealership_city.presence || 'your dealership'}",
          'Add interests: Manufactured homes, Home buying, First-time homebuyer',
          'Upload the images from this post',
          'Paste the Primary Text, Headline, and Description from below',
          'Select your Lead Form (or create one that matches your intake form)',
          'Review and publish'
        ]
      }
    end

    # Ladder: smaller unit price → smaller budget. Market size proxy could be
    # layered in later when we track dealership metros.
    def recommended_budget(price)
      case price.to_f
      when 0...60_000     then { daily_min: 10, daily_max: 25 }
      when 60_000...100_000 then { daily_min: 15, daily_max: 40 }
      when 100_000...150_000 then { daily_min: 25, daily_max: 60 }
      else                      { daily_min: 35, daily_max: 100 }
      end
    end

    # ------------------------------------------------------------------
    # Context
    # ------------------------------------------------------------------
    def build_context(company:, vehicle:, user:, intent_category:, post_type:, platform:, tone:, topic_details: nil, intake_form_url: nil)
      {
        company: {
          id:    company&.id,
          name:  company&.name,
          city:  company&.try(:city),
          state: company&.try(:state),
          phone: company&.try(:phone) || company&.try(:primary_phone)
        },
        vehicle: vehicle ? vehicle_context(vehicle) : nil,
        user: user ? {
          id:         user.id,
          first_name: user.first_name,
          last_name:  user.last_name
        } : nil,
        intent_category: intent_category,
        post_type:       post_type,
        platform:        platform,
        tone:            tone,
        topic_details:   topic_details,
        intake_form_url: intake_form_url,
        voice:           post_type == 'rep_personal' ? 'first_person' : 'company_plural',
        length_hint:     platform.to_s == 'instagram' ? 'short (80-120 words)' : 'up to 250 words',
        hashtag_hint:    platform.to_s == 'instagram' ? '8-15 hashtags' : '3-6 hashtags'
      }
    end

    def vehicle_context(v)
      primary_photo = v.try(:photo_url).presence ||
                      (Array(v.try(:images)).first.is_a?(Hash) ? Array(v.try(:images)).first['url'] : Array(v.try(:images)).first)

      age_days = ((Time.current - (v.date_in_stock || v.created_at)) / 1.day).to_i rescue nil

      {
        id:            v.id,
        year:          v.year,
        make:          v.make,
        model:         v.model,
        bedrooms:      v.try(:bedrooms),
        bathrooms:     v.try(:bathrooms),
        square_feet:   v.try(:square_feet),
        sale_price:    v.try(:sale_price),
        condition:     v.try(:condition),
        stock_number:  v.try(:stock_number),
        vin:           v.try(:vin),
        city:          v.try(:location_city),
        state:         v.try(:location_state),
        primary_photo_url: primary_photo,
        days_in_stock: age_days
      }
    end

    # ------------------------------------------------------------------
    # Prompts
    # ------------------------------------------------------------------
    def build_system_prompt(ctx)
      <<~PROMPT.strip
        You are a social media expert for manufactured housing and RV dealerships.
        Write content that is warm, local, compliant, and conversion-oriented.
        Voice: #{ctx[:voice] == 'first_person' ? 'first person ("I", "my")' : 'company plural ("we", "our")'}.
        Tone: #{ctx[:tone]}.
        Platform: #{ctx[:platform]} — keep caption #{ctx[:length_hint]} and use #{ctx[:hashtag_hint]}.
        Compliance: whenever price appears, append "Subject to change. See dealer for details." to the description.
        Return ONLY valid JSON — no prose, no markdown, no code fences — with keys:
        caption (string), headline (string, under 80 chars), description (string),
        hashtags (array of strings, no leading '#'), cta_type (one of: learn_more, get_directions, message_us, apply_now, shop_now, call_now).
      PROMPT
    end

    def build_user_prompt(ctx)
      sections = []
      sections << intent_instructions(ctx[:intent_category], ctx)
      sections << "Dealer context:\n#{format_company(ctx[:company])}"
      sections << "Unit context:\n#{format_vehicle(ctx[:vehicle])}" if ctx[:vehicle]
      sections << "Sales rep:\n#{format_user(ctx[:user])}"          if ctx[:user] && ctx[:post_type] == 'rep_personal'
      sections << "Additional context from the user:\n#{ctx[:topic_details]}" if ctx[:topic_details].present?
      sections << "Include this lead capture link in the caption (with UTM tracking already applied): #{ctx[:intake_form_url]}" if ctx[:intake_form_url].present?
      sections << "Return JSON only."
      sections.join("\n\n")
    end

    def intent_instructions(intent, ctx)
      case intent
      when 'specific_unit'
        "Write a social post that features THIS specific home. Lead with the year/make/model, call out bedrooms/bathrooms, price, and photo-worthy feature. CTA = shop_now."
      when 'price_drop'
        "Write a short, urgent social post about a price reduction on this home. Use a clear before/after framing if possible, otherwise emphasize that the price just dropped. CTA = shop_now."
      when 'social_proof'
        "Write a celebration post about a family getting into their new home. Keep the home specifics light; lead with the feeling of 'welcome home'. CTA = message_us."
      when 'education'
        "Write an educational post about the benefits of manufactured housing (affordability, customization, speed, energy efficiency, quality). Do NOT hard-sell a specific unit. CTA = learn_more."
      when 'financing'
        "Write an accessible, non-intimidating post about financing options (programs for first-time buyers, land-home, etc.). Avoid rate promises. CTA = apply_now."
      when 'lifestyle'
        "Write a lifestyle / community post centered on life in the area (schools, parks, outdoors). Soft tie-in to the dealership. CTA = learn_more."
      when 'seasonal'
        "Write a seasonal promotion post tied to current season/holiday. Emphasize timing without being gimmicky. CTA = shop_now."
      when 'rep_personal'
        "Write a personal-voice post from a single sales rep's perspective. First person, conversational, warm. Mention one concrete thing happening at the lot this week. CTA = message_us."
      when 'new_arrival'
        "Write a 'just arrived' announcement. Lead with the newness. If a unit is provided, showcase it. CTA = shop_now."
      when 'aged_inventory'
        dwell = ctx.dig(:vehicle, :days_in_stock)
        "Write a post that refreshes interest in a home that's been on the lot for #{dwell || '60+'} days. Re-frame it as an opportunity (well-kept, ready-to-move, price negotiation possible). CTA = message_us."
      when 'ad_content'
        <<~AD.strip
          Generate Facebook/Instagram ad content for this unit. Produce three ad fields:
          1. PRIMARY TEXT  — the main ad copy, 125 characters max for best performance. Put this in `caption`.
          2. HEADLINE      — 40 characters max, shown below the image. Put this in `headline`.
          3. DESCRIPTION   — 30 characters max, shown below the headline. Put this in `description`.
          CTA should be `lead_generation` or `shop_now`. Hashtags optional (≤3).
          Stay punchy; do not exceed the character limits.
        AD
      else
        "Write a general social post for this dealership."
      end
    end

    def format_company(c)
      return 'unknown dealership' unless c
      parts = []
      parts << "Name: #{c[:name]}" if c[:name].present?
      parts << "Location: #{[c[:city], c[:state]].reject(&:blank?).join(', ')}" if c[:city].present? || c[:state].present?
      parts << "Phone: #{c[:phone]}" if c[:phone].present?
      parts.join("\n")
    end

    def format_vehicle(v)
      return 'no specific unit' unless v
      parts = []
      parts << "Unit: #{[v[:year], v[:make], v[:model]].compact.join(' ')}"
      parts << "Bedrooms: #{v[:bedrooms]}" if v[:bedrooms]
      parts << "Bathrooms: #{v[:bathrooms]}" if v[:bathrooms]
      parts << "Square feet: #{v[:square_feet]}" if v[:square_feet]
      parts << "Price: $#{format_price(v[:sale_price])}" if v[:sale_price]
      parts << "Condition: #{v[:condition]}" if v[:condition]
      parts << "Stock #: #{v[:stock_number]}" if v[:stock_number]
      parts << "Days in stock: #{v[:days_in_stock]}" if v[:days_in_stock]
      parts << "Photo URL: #{v[:primary_photo_url]}" if v[:primary_photo_url]
      parts.join("\n")
    end

    def format_user(u)
      return '' unless u
      "#{u[:first_name]} #{u[:last_name]}".strip
    end

    def format_price(price)
      BigDecimal(price.to_s).to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    rescue
      price.to_s
    end

    # ------------------------------------------------------------------
    # Claude call
    # ------------------------------------------------------------------
    def call_claude(api_key, system_prompt, user_prompt)
      uri = URI('https://api.anthropic.com/v1/messages')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30
      http.open_timeout = 10

      request = Net::HTTP::Post.new(uri)
      request['Content-Type']      = 'application/json'
      request['x-api-key']         = api_key
      request['anthropic-version'] = '2023-06-01'
      request.body = {
        model:      MODEL,
        max_tokens: MAX_TOKENS,
        system:     system_prompt,
        messages:   [{ role: 'user', content: user_prompt }]
      }.to_json

      response = http.request(request)
      unless response.code == '200'
        raise Error, "Claude API error (#{response.code}): #{response.body.to_s.truncate(300)}"
      end

      JSON.parse(response.body)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise Error, "Claude timeout: #{e.message}"
    end

    def parse_model_output(response)
      text = response.dig('content', 0, 'text').to_s.strip
      # Tolerate stray code fences even though the system prompt forbids them.
      cleaned = text.sub(/\A```(?:json)?\s*/i, '').sub(/\s*```\z/, '').strip

      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      raise Error, "Claude returned non-JSON content: #{e.message}"
    end
  end
end
