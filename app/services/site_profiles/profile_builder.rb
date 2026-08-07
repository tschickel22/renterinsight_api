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

    # The model sees image URLs and alt text, not the pixels, so it cannot judge
    # a photo on sight. Telling it what a hero is FOR is what makes the alt text
    # and surrounding headings usable as evidence.
    #
    # Written after real scans put a dealer's American flag graphic behind the
    # headline of every page. Deterministic filters now bar that image from
    # hero_images regardless, but the model choosing well in the first place
    # produces a better page than a filter salvaging a bad list.
    IMAGE_SELECTION_RULES = <<~RULES.freeze
      IMAGE SELECTION

      hero_images must contain ONLY photographs of homes: manufactured, modular
      or mobile home exteriors, model homes on a lot, or a home's interior
      living space. These sit full-bleed behind a headline, so they need to be
      large photographs with room for text over them.

      Never put any of these in hero_images:
        - flags, bunting, fireworks, or any patriotic or seasonal decoration
        - sale banners, promotional graphics, price tags, or anything with
          marketing text baked into the image
        - logos, badges, awards, BBB or review widgets, lender or financing
          partner marks
        - staff portraits, group photos, handshakes, or generic office stock
        - maps, floor plan line drawings, icons, or spacers

      Judge from the file name AND the alt text AND the headings around it. If
      the alt text says "4th of July Sale" or the file is called
      banner-july4.jpg, it is a promotion, not a home, no matter how large it is.

      When you are unsure whether an image is a home, leave it out. An empty
      hero_images list is fine and is handled downstream; a flag behind a
      headline is not.

      gallery may include the promotional and seasonal images, since it is
      browsed rather than read at a glance. Put homes first there too.
    RULES

    def initialize(company:, user: nil)
      @company = company
      @user = user
    end

    # digests: [PageDigest::Digest], brand/links/integrations from the
    # deterministic pass. Returns [profile_hash, warnings, usage].
    # images: rendered document pages (DocumentRasterizer output). A crawl passes
    # none — page text is the content. A document upload passes its pages,
    # because a product sheet's meaning lives in its layout and photography, and
    # its extracted text is routinely mangled by letter-spacing ("TheCompleteDMSfor").
    # inventory_images: photographs of homes on a lot we already hold, used when
    # the scan yields no usable hero. See SiteProfiles::InventoryImagery.
    def call(digests:, brand: {}, links: {}, integrations: [], contact: {}, source_url: nil,
             images: [], inventory_images: [])
      started = Time.current
      @inventory_images = Array(inventory_images)
      response = call_claude(
        system_prompt: system_prompt(document: images.present?),
        user_message: build_content(user_message(digests, brand, source_url), images),
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

      profile['media'] = merge_media(profile['media'].to_h, digests)
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

    # Background images are where dealer sites keep their photography, so
    # hero/gallery are seeded from them when the model did not pick any.
    #
    # This used to be two lines that appended every candidate to whatever the
    # model chose:
    #
    #   candidates = digests.flat_map(&:candidate_hero_images).uniq
    #   media['hero_images'] = (Array(media['hero_images']) + candidates).uniq.first(12)
    #
    # Three separate defects, which together are why a dealer's American flag
    # graphic ended up behind the headline on every generated page:
    #
    #   1. flat_map across pages destroyed the per-page demotion. Each digest
    #      returned photos-then-promos, so concatenating page by page put page
    #      one's promotional banner ahead of page two's real photography.
    #   2. Appending re-added everything the model had deliberately left out.
    #      Filtering the model could do was discarded a line later.
    #   3. Nothing was ever rejected outright. A demoted image still reached
    #      hero_images, and reaching it at all is enough — a hero band renders
    #      whichever image is at index 0 of the list it is given.
    #
    # Now: promotional and non-home imagery is barred from hero_images entirely
    # and kept only for the gallery, and if that leaves nothing usable we fall
    # back to photographs of real homes we already hold rather than to whatever
    # was on the page.
    def merge_media(media, digests)
      # Concatenate all pages' keepers, THEN all pages' demoted, so ordering
      # survives the merge.
      keepers = digests.flat_map(&:candidate_hero_images).uniq
      demoted = (digests.flat_map(&:demoted_images).uniq - keepers)

      chosen = Array(media['hero_images']).select { |url| hero_worthy?(url) }
      heroes = (chosen + keepers).uniq

      # An empty hero list is worse than a wrong one: the template falls through
      # to stock imagery that belongs to nobody. Our own lot is a better answer.
      heroes = inventory_fallback if heroes.empty?

      media['hero_images'] = heroes.first(12)
      # The gallery is browsed rather than read at a glance, so a seasonal
      # banner is merely uninteresting there instead of wrong. It still sorts
      # last.
      media['gallery'] = (Array(media['gallery']) + heroes + demoted).uniq.first(24)
      media
    end

    def hero_worthy?(url)
      value = url.to_s
      return false if value.blank?

      !PageDigest::PROMOTIONAL.match?(value) &&
        !PageDigest::NOT_A_HOME.match?(value) &&
        !PageDigest::JUNK_IMAGE.match?(value)
    end

    def inventory_fallback
      @inventory_images.presence || []
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

    def system_prompt(document: false)
      return document_system_prompt if document

      <<~PROMPT
        You extract structured content from a manufactured-housing or RV dealer's
        existing website so it can be rebuilt on a new platform.

        You are given compact digests of several pages: headings, paragraphs,
        image URLs, link text and form fields. Your job is to normalise that into
        reusable content sections.

        #{IMAGE_SELECTION_RULES}

        #{ProfileSchema.prompt_contract}
      PROMPT
    end

    def document_system_prompt
      <<~PROMPT
        You extract structured content from a document a manufactured-housing or
        RV dealer supplied — typically a product sheet, brochure or spec packet —
        so a landing page can be built from it.

        You are given the document's extracted text AND an image of every page.

        Trust the images over the text. The text comes from a PDF extractor and
        is frequently mangled: letter-spaced headings collapse into runs like
        "TheCompleteDMSfor", columns interleave, and table cells arrive out of
        order. Read the page images to recover what it actually says, and use the
        text only to confirm exact spellings, figures and spec values.

        #{IMAGE_SELECTION_RULES}

        Also read from the images what the text cannot carry: the brand's colours
        (as hex), the typographic feel, which photograph is the hero, and which
        content is a headline versus a caption versus a spec table.

        #{ProfileSchema.prompt_contract}
      PROMPT
    end

    # Claude's `content` takes either a string or an array of blocks, so a
    # text-only crawl stays exactly as it was.
    def build_content(text, images)
      return text if images.blank?

      [{ type: 'text', text: text }] + images.map do |img|
        {
          type: 'image',
          source: {
            type: 'base64',
            media_type: img['content_type'].to_s.downcase,
            data: img['data_base64'].to_s
          }
        }
      end
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
