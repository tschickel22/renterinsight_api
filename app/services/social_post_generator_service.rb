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

  MODEL             = AiModel.for(:generation)
  MAX_TOKENS        = 800
  MAX_IMAGES        = 4
  MAX_PAST_EXAMPLES = 5
  VERSION           = 'spg-2026-07-01'

  class << self
    def generate(company:, intent_category:, post_type:, platform:, vehicle: nil, user: nil, tone: 'friendly', topic_details: nil, intake_form_url: nil, image_urls: [], current_draft: nil)
      profile = SocialPostIntentCatalog.for_company(company)
      unless profile.intent_values.include?(intent_category)
        raise Error, "invalid intent_category '#{intent_category}' for this industry. Must be one of: #{profile.intent_values.join(', ')}"
      end

      api_key = resolve_api_key
      raise Error, 'Anthropic API key is not configured' if api_key.blank?

      ctx = build_context(company: company, vehicle: vehicle, user: user,
                          intent_category: intent_category, post_type: post_type,
                          platform: platform, tone: tone,
                          topic_details: topic_details, intake_form_url: intake_form_url,
                          image_urls: image_urls, current_draft: current_draft,
                          profile: profile)

      prompt        = build_user_prompt(ctx)
      system_prompt = build_system_prompt(ctx)

      response = begin
        call_claude(api_key, system_prompt, prompt, ctx[:image_urls])
      rescue Error => e
        # If the vision call fails (e.g. an image URL Anthropic can't fetch),
        # don't fail the whole generation — retry text-only.
        raise e if ctx[:image_urls].blank?
        Rails.logger.warn "[SocialPostGeneratorService] image-aware generate failed (#{e.message}); retrying text-only"
        call_claude(api_key, system_prompt, prompt, [])
      end
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

      payload[:ad_settings] = build_ad_settings(company: company, vehicle: vehicle, profile: profile) if intent_category == 'ad_content'
      payload
    end

    private

    def resolve_api_key
      Rails.application.credentials.dig(:anthropic, :api_key) || ENV['ANTHROPIC_API_KEY']
    end

    # ------------------------------------------------------------------
    # Ad settings (for intent_category == 'ad_content')
    # ------------------------------------------------------------------
    def build_ad_settings(company:, vehicle:, profile:)
      price = vehicle.try(:sale_price).to_f if vehicle
      budget = recommended_budget(price)
      city = company&.try(:city).to_s

      if profile.family == :dealer
        interests = ['Manufactured homes', 'Home buying', 'Real estate', 'First-time homebuyer', 'Affordable housing']
        {
          recommended_audience: { age_min: 25, age_max: 65, radius_miles: 50, interests: interests },
          recommended_budget:    budget,
          recommended_objective: 'lead_generation',
          setup_instructions: [
            'Go to Facebook Ads Manager (business.facebook.com)',
            'Click Create → Choose objective: Lead Generation',
            "Set your daily budget to $#{budget[:daily_min]}-$#{budget[:daily_max]}",
            "Target: Age 25-65, within 50 miles of #{city.presence || 'your dealership'}",
            "Add interests: #{interests.first(3).join(', ')}",
            'Upload the images from this post',
            'Paste the Primary Text, Headline, and Description from below',
            'Select your Lead Form (or create one that matches your intake form)',
            'Review and publish'
          ]
        }
      else
        # SaaS / generic: no physical radius, audience driven by the business's
        # own target-audience description rather than fixed home-buying interests.
        {
          recommended_audience: { age_min: 25, age_max: 64, radius_miles: nil, interests: [] },
          recommended_budget:    budget,
          recommended_objective: 'lead_generation',
          setup_instructions: [
            'Go to Facebook Ads Manager (business.facebook.com)',
            'Click Create → Choose objective: Lead Generation (or Traffic for a trial/demo page)',
            "Set your daily budget to $#{budget[:daily_min]}-$#{budget[:daily_max]}",
            'Target your ideal-customer audience (job titles, industries, and interests from your target-audience profile)',
            'Upload the images from this post',
            'Paste the Primary Text, Headline, and Description from below',
            'Select your Lead Form, or point the ad at your trial/demo landing page',
            'Review and publish'
          ]
        }
      end
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
    def build_context(company:, vehicle:, user:, intent_category:, post_type:, platform:, tone:, topic_details: nil, intake_form_url: nil, image_urls: [], current_draft: nil, profile: nil)
      profile ||= SocialPostIntentCatalog.for_company(company)
      {
        image_urls:    sanitize_image_urls(image_urls),
        current_draft: sanitize_current_draft(current_draft),
        company: {
          id:    company&.id,
          name:  company&.name,
          city:  company&.try(:city),
          state: company&.try(:state),
          phone: company&.try(:phone) || company&.try(:primary_phone)
        },
        business: business_profile(company),
        industry:      company&.try(:industry),
        family:        profile.family.to_s,
        persona:       profile.persona,
        compliance:    profile.compliance,
        subject_label: profile.subject_label,
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
        hashtag_hint:    platform.to_s == 'instagram' ? '8-15 hashtags' : '3-6 hashtags',
        past_examples:   past_examples(company: company, intent_category: intent_category, platform: platform)
      }
    end

    # Pulls the company's best-performing published posts as few-shot style
    # examples so the model can match this specific dealership's voice, cadence,
    # and hashtag habits — not just the generic intent instructions.
    #
    # Ranking prefers same intent + same platform, then same intent (any
    # platform), then any recent published post from the company. Engagement
    # score weights link_clicks and engagement_count more heavily than raw
    # impressions since they signal audience response, not just reach.
    def past_examples(company:, intent_category:, platform:, limit: MAX_PAST_EXAMPLES)
      return [] unless company&.id

      base = SocialPost
        .where(company_id: company.id, status: 'published')
        .where(is_deleted: [false, nil])
        .where.not(caption: [nil, ''])

      primary = ranked_examples(base.where(intent_category: intent_category, platform: platform), limit)
      collected_ids = primary.map(&:id)

      if primary.size < limit
        same_intent = ranked_examples(
          base.where(intent_category: intent_category).where.not(id: collected_ids),
          limit - primary.size
        )
        primary += same_intent
        collected_ids = primary.map(&:id)
      end

      if primary.size < limit
        fallback = ranked_examples(base.where.not(id: collected_ids), limit - primary.size)
        primary += fallback
      end

      primary.map { |p| example_payload(p) }
    rescue => e
      Rails.logger.warn "[SocialPostGeneratorService] past_examples failed: #{e.message}"
      []
    end

    def ranked_examples(scope, limit)
      return [] if limit <= 0
      order_sql = Arel.sql(
        'COALESCE(impressions,0) + COALESCE(link_clicks,0) * 5 + COALESCE(engagement_count,0) * 3 DESC, ' \
        'published_at DESC NULLS LAST, id DESC'
      )
      scope.order(order_sql).limit(limit).to_a
    end

    def example_payload(post)
      {
        intent_category: post.intent_category,
        platform:        post.platform,
        caption:         post.caption.to_s.truncate(400),
        headline:        post.headline.presence,
        description:     post.description.to_s.truncate(200).presence,
        engagement: {
          impressions:      post.impressions.to_i,
          link_clicks:      post.link_clicks.to_i,
          engagement_count: post.engagement_count.to_i
        }
      }.compact
    end

    # Only pass http(s) URLs (Anthropic must be able to fetch them), capped so a
    # post with many images doesn't blow up the request.
    def sanitize_image_urls(urls)
      Array(urls).map { |u| u.to_s.strip }.select { |u| u.match?(%r{\Ahttps?://}i) }.first(MAX_IMAGES)
    end

    # The fields the user may have already filled in. We feed these back so the
    # model writes the remaining fields consistently — and the caller fills only
    # blanks, so nothing the user typed gets overwritten.
    def sanitize_current_draft(draft)
      return nil if draft.blank?
      d = draft.respond_to?(:to_unsafe_h) ? draft.to_unsafe_h : draft
      d = d.transform_keys(&:to_s)
      cleaned = {
        'caption'     => d['caption'].to_s.strip.presence,
        'headline'    => d['headline'].to_s.strip.presence,
        'description' => d['description'].to_s.strip.presence,
        'hashtags'    => Array(d['hashtags']).map { |h| h.to_s.strip }.reject(&:blank?),
        'cta_type'    => d['cta_type'].to_s.strip.presence
      }
      cleaned['hashtags'] = nil if cleaned['hashtags'].blank?
      cleaned.compact.presence
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

    # Pulls the company "about" profile (business_description, target_audience,
    # products_services, value props, brand voice) the same way the campaigns
    # AI builder does. Tolerates the historically inconsistent key casing.
    def business_profile(company)
      return {} unless company&.id
      profile = Setting.get('Company', company.id, 'company_profile') ||
                Setting.get('company', company.id, 'company_profile') || {}
      {
        business_description: profile['business_description'].presence || company.try(:description).to_s.presence,
        target_audience:      profile['target_audience'],
        products_services:    profile['products_services'],
        value_props:          profile['unique_value_props'].presence || profile['key_differentiators'],
        industry_vertical:    profile['industry_vertical'],
        brand_voice:          profile['brand_voice'],
        website:              company.try(:website).to_s.presence
      }.compact
    rescue => e
      Rails.logger.warn "[SocialPostGeneratorService] business_profile failed: #{e.message}"
      {}
    end

    # ------------------------------------------------------------------
    # Prompts
    # ------------------------------------------------------------------
    def build_system_prompt(ctx)
      lines = []
      lines << ctx[:persona]
      lines << "Voice: #{ctx[:voice] == 'first_person' ? 'first person ("I", "my")' : 'company plural ("we", "our")'}."
      lines << "Tone: #{ctx[:tone]}."
      lines << "Platform: #{ctx[:platform]} — keep caption #{ctx[:length_hint]} and use #{ctx[:hashtag_hint]}."
      if ctx[:image_urls].present?
        lines << "One or more images are attached to this post. Look at them and make the caption, headline, description, and hashtags reflect what is actually shown — reference specific visual details where it helps."
      end
      if ctx[:current_draft].present?
        lines << "The user has already written some fields (shown under \"Current draft\"). Treat those as fixed: do not contradict them, and make any fields you generate consistent in subject, tone, and detail with what the user wrote."
      end
      if ctx[:past_examples].present?
        lines << "You will see past posts from this business under \"Past posts from this business\". Match their voice, cadence, sentence length, emoji usage, and hashtag style. Do NOT copy their content — write something new for the current subject."
      end
      lines << ctx[:compliance] if ctx[:compliance].present?
      lines << <<~OUT.strip
        Return ONLY valid JSON — no prose, no markdown, no code fences — with keys:
        caption (string), headline (string, under 80 chars), description (string),
        hashtags (array of strings, no leading '#'), cta_type (one of: learn_more, get_directions, message_us, apply_now, shop_now, call_now).
      OUT
      lines.join("\n")
    end

    def build_user_prompt(ctx)
      sections = []
      sections << intent_instructions(ctx[:intent_category], ctx)
      sections << "Business context:\n#{format_company(ctx[:company])}"
      biz = format_business(ctx[:business])
      sections << "About the business (use this as primary context for what to say):\n#{biz}" if biz.present?
      sections << "#{ctx[:subject_label].to_s.capitalize} context:\n#{format_vehicle(ctx[:vehicle])}" if ctx[:vehicle]
      sections << "Person posting:\n#{format_user(ctx[:user])}" if ctx[:user] && ctx[:post_type] == 'rep_personal'
      sections << "Additional context from the user:\n#{ctx[:topic_details]}" if ctx[:topic_details].present?
      draft = format_current_draft(ctx[:current_draft])
      sections << "Current draft (already written by the user — keep these consistent and complement them; do not rewrite them):\n#{draft}" if draft.present?
      examples = format_past_examples(ctx[:past_examples])
      sections << "Past posts from this business (style reference only — match the voice, not the content):\n#{examples}" if examples.present?
      sections << "The attached image(s) belong to this post — describe and reference what they show." if ctx[:image_urls].present?
      sections << "Include this lead capture link in the caption (with UTM tracking already applied): #{ctx[:intake_form_url]}" if ctx[:intake_form_url].present?
      sections << "Return JSON only."
      sections.join("\n\n")
    end

    def format_past_examples(examples)
      return '' if examples.blank?
      examples.each_with_index.map do |ex, i|
        parts = []
        tag = [ex[:intent_category], ex[:platform]].compact.join(' · ')
        parts << "#{i + 1}. [#{tag}]"
        parts << "   Caption: #{ex[:caption]}" if ex[:caption].present?
        parts << "   Headline: #{ex[:headline]}" if ex[:headline].present?
        parts << "   Description: #{ex[:description]}" if ex[:description].present?
        parts.join("\n")
      end.join("\n\n")
    end

    def format_current_draft(d)
      return '' if d.blank?
      parts = []
      parts << "Caption: #{d['caption']}" if d['caption'].present?
      parts << "Headline: #{d['headline']}" if d['headline'].present?
      parts << "Description: #{d['description']}" if d['description'].present?
      parts << "Hashtags: #{Array(d['hashtags']).map { |h| "##{h}" }.join(' ')}" if d['hashtags'].present?
      parts << "Call to action: #{d['cta_type']}" if d['cta_type'].present?
      parts.join("\n")
    end

    def intent_instructions(intent, ctx)
      profile = SocialPostIntentCatalog::PROFILES.fetch(ctx[:family].to_sym)
      entry   = profile.intent(intent)
      return "Write a general social post for this business." unless entry

      instr = entry.instruction
      instr.respond_to?(:call) ? instr.call(ctx) : instr
    end

    def format_company(c)
      return 'unknown business' unless c
      parts = []
      parts << "Name: #{c[:name]}" if c[:name].present?
      parts << "Location: #{[c[:city], c[:state]].reject(&:blank?).join(', ')}" if c[:city].present? || c[:state].present?
      parts << "Phone: #{c[:phone]}" if c[:phone].present?
      parts.join("\n")
    end

    def format_business(b)
      return '' if b.blank?
      parts = []
      parts << "Description: #{b[:business_description]}" if b[:business_description].present?
      parts << "Target audience: #{b[:target_audience]}" if b[:target_audience].present?
      parts << "Products/services: #{b[:products_services]}" if b[:products_services].present?
      parts << "Value proposition: #{b[:value_props]}" if b[:value_props].present?
      parts << "Brand voice: #{b[:brand_voice]}" if b[:brand_voice].present?
      parts << "Website: #{b[:website]}" if b[:website].present?
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
    def call_claude(api_key, system_prompt, user_prompt, image_urls = [])
      uri = URI('https://api.anthropic.com/v1/messages')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30
      http.open_timeout = 10

      content = Array(image_urls).map do |url|
        { type: 'image', source: { type: 'url', url: url } }
      end
      content << { type: 'text', text: user_prompt }

      request = Net::HTTP::Post.new(uri)
      request['Content-Type']      = 'application/json'
      request['x-api-key']         = api_key
      request['anthropic-version'] = '2023-06-01'
      request.body = {
        model:      MODEL,
        max_tokens: MAX_TOKENS,
        system:     system_prompt,
        messages:   [{ role: 'user', content: content }]
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
