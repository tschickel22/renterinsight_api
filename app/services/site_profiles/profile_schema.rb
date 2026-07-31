# frozen_string_literal: true

module SiteProfiles
  # The Client Content Profile contract.
  #
  # Deliberately SEMANTIC and block-agnostic: sections like "hero" and
  # "testimonials", never block types. The moment this emits blocks it stops
  # projecting into templates that do not exist yet, which is the entire reason
  # the profile is a durable artifact rather than a one-shot site.
  #
  # Versioned because it is a persisted contract between the scan phase and the
  # projection phase — an old profile must stay projectable after the shape moves.
  module ProfileSchema
    VERSION = 1

    # section => keys we keep. Anything else the model returns is dropped.
    COPY_SECTIONS = {
      'hero' => %w[headline subhead cta_text cta_href],
      'about' => %w[heading body],
      'services' => %w[title description icon_hint],
      'differentiators' => %w[title description],
      'testimonials' => %w[quote author role],
      'team' => %w[name role photo phone email bio],
      'faq' => %w[question answer],
      'stats' => %w[number label suffix],
      'process' => %w[title description]
    }.freeze

    MAX_ITEMS_PER_SECTION = 12

    module_function

    def empty
      {
        'schema_version' => VERSION,
        'brand' => {},
        'contact' => {},
        'copy' => COPY_SECTIONS.keys.index_with { [] },
        'media' => { 'hero_images' => [], 'gallery' => [] },
        'links' => { 'internal' => [], 'external' => [] },
        'integrations' => [],
        'seo' => {},
        'source' => { 'warnings' => [] }
      }
    end

    # Coerce whatever the model returned into the contract.
    #
    # Repair, never raise. A thin profile still projects into nine templates; an
    # exception means the admin waited three minutes for nothing. Every dropped
    # field is reported so the failure is visible rather than silent.
    def coerce(raw)
      warnings = []
      raw = {} unless raw.is_a?(Hash)
      out = empty

      out['brand'] = slice_strings(raw['brand'], %w[name tagline logo_url])
      if raw.dig('brand', 'colors').is_a?(Hash)
        out['brand']['colors'] = slice_strings(raw['brand']['colors'], %w[primary secondary accent])
      end
      if raw.dig('brand', 'fonts').is_a?(Hash)
        out['brand']['fonts'] = slice_strings(raw['brand']['fonts'], %w[heading body])
      end

      out['contact'] = slice_strings(raw['contact'], %w[phone email address hours])
      if raw.dig('contact', 'social').is_a?(Hash)
        out['contact']['social'] = raw['contact']['social'].transform_values(&:to_s).compact_blank
      end

      COPY_SECTIONS.each do |section, keys|
        items = raw.dig('copy', section)
        unless items.is_a?(Array)
          warnings << "copy.#{section} was #{items.class.name.downcase}, expected array" if items.present?
          next
        end

        out['copy'][section] = items.filter_map do |item|
          next unless item.is_a?(Hash)

          entry = slice_strings(item, keys)
          entry.presence
        end.first(MAX_ITEMS_PER_SECTION)
      end

      out['media'] = {
        'logo' => raw.dig('media', 'logo').presence,
        'og_image' => raw.dig('media', 'og_image').presence,
        'hero_images' => string_array(raw.dig('media', 'hero_images')),
        'gallery' => string_array(raw.dig('media', 'gallery'))
      }.compact

      out['seo'] = slice_strings(raw['seo'], %w[title description])
      out['seo']['keywords'] = string_array(raw.dig('seo', 'keywords')).first(20)

      unknown = raw.keys - (empty.keys + %w[copy])
      warnings << "ignored unknown top-level keys: #{unknown.join(', ')}" if unknown.any?

      [out, warnings]
    end

    def slice_strings(hash, keys)
      return {} unless hash.is_a?(Hash)

      keys.index_with { |k| hash[k].is_a?(String) ? hash[k].strip.presence : nil }.compact
    end

    def string_array(value)
      return [] unless value.is_a?(Array)

      value.filter_map { |v| v.to_s.strip.presence if v.is_a?(String) }
    end

    # Rendered into the system prompt so the model returns exactly this.
    def prompt_contract
      <<~CONTRACT
        Return ONE JSON object, no prose and no markdown fences, with this shape:

        {
          "brand":   { "name": str, "tagline": str,
                       "colors": { "primary": "#rrggbb", "secondary": str, "accent": str },
                       "fonts":  { "heading": str, "body": str } },
          "contact": { "phone": str, "email": str, "address": str, "hours": str,
                       "social": { "facebook": url, "instagram": url } },
          "copy": {
            "hero":            [{ "headline": str, "subhead": str, "cta_text": str, "cta_href": str }],
            "about":           [{ "heading": str, "body": str }],
            "services":        [{ "title": str, "description": str, "icon_hint": str }],
            "differentiators": [{ "title": str, "description": str }],
            "testimonials":    [{ "quote": str, "author": str, "role": str }],
            "team":            [{ "name": str, "role": str, "photo": url, "phone": str, "email": str, "bio": str }],
            "faq":             [{ "question": str, "answer": str }],
            "stats":           [{ "number": str, "label": str, "suffix": str }],
            "process":         [{ "title": str, "description": str }]
          },
          "media": { "logo": url, "og_image": url, "hero_images": [url], "gallery": [url] },
          "seo":   { "title": str, "description": str, "keywords": [str] }
        }

        RULES
        - Use ONLY text present on the pages. Never invent testimonials, staff,
          statistics, or claims — a fabricated review on a real dealer's site is
          a serious problem.
        - Omit a section entirely rather than padding it with filler.
        - Preserve the dealer's own voice and phrasing; do not rewrite in
          generic marketing language.
        - Absolute URLs only.
        - Do NOT emit page blocks, layouts, or HTML. Sections only.
      CONTRACT
    end
  end
end
