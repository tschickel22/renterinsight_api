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
    # 2 added the product sections below. Old profiles stay projectable: the
    # sections default to [] and every consumer already tolerates empty ones.
    VERSION = 2

    # section => keys we keep. Anything else the model returns is dropped.
    #
    # The first block is site-shaped — what a dealer's homepage is made of. The
    # second is document-shaped: a product sheet is not a homepage, and asking
    # the model to force a spec table into "services" loses the specs. Both live
    # in one map so coercion, capping and the empty profile stay uniform, and so
    # a scanned site that happens to describe a product can fill them too.
    COPY_SECTIONS = {
      'hero' => %w[headline subhead cta_text cta_href],
      'about' => %w[heading body],
      'services' => %w[title description icon_hint],
      'differentiators' => %w[title description],
      'testimonials' => %w[quote author role],
      'team' => %w[name role photo phone email bio],
      'faq' => %w[question answer],
      'stats' => %w[number label suffix],
      'process' => %w[title description],

      # An array rather than a single object: one brochure routinely covers
      # several floor plans or trim levels, and collapsing them loses all but one.
      'product' => %w[name model_number summary msrp],
      'specs' => %w[label value unit group],
      'features' => %w[title description icon_hint],
      'options' => %w[title description price],
      'floorplan' => %w[name beds baths sqft dimensions image_url]
    }.freeze

    # Sections that only a document upload is expected to fill. Used to report
    # honestly when a product sheet scan came back with no product content —
    # otherwise a failed extraction looks identical to a sparse document.
    PRODUCT_SECTIONS = %w[product specs features options floorplan].freeze

    MAX_ITEMS_PER_SECTION = 12

    # What a model says when it does not know. Never a real value.
    PLACEHOLDER_VALUE = /\A(unknown|n\/?a|none|null|undefined|not (?:found|specified|available)|tbd|-)\z/i

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
        colors = slice_strings(raw['brand']['colors'], %w[primary secondary accent])
        # The model answers "unknown" when it cannot tell, and a bare string
        # check let that through — a real site shipped with primary_color
        # "#unknown" after the backend prefixed it. Anything that is not a hex
        # colour is dropped so the template's own palette survives.
        rejected = colors.reject { |_, v| hex_colour?(v) }
        warnings << "dropped non-colour brand values: #{rejected.values.join(', ')}" if rejected.any?
        out['brand']['colors'] = colors.select { |_, v| hex_colour?(v) }.presence
        out['brand'].delete('colors') if out['brand']['colors'].nil?
      end
      if raw.dig('brand', 'fonts').is_a?(Hash)
        fonts = slice_strings(raw['brand']['fonts'], %w[heading body])
        fonts = fonts.reject { |_, v| PLACEHOLDER_VALUE.match?(v) }
        # Asked to name a font from a page image, the model hedges in prose —
        # "sans-serif bold (appears to be a geometric sans)" came back from a
        # real scan. That lands in a template's font-family and renders as
        # nothing. Anything that is not a plausible family name is dropped so
        # the template's own typography survives.
        rejected_fonts = fonts.reject { |_, v| font_family?(v) }
        if rejected_fonts.any?
          warnings << "dropped unusable font values: #{rejected_fonts.values.join(', ')}"
        end
        fonts = fonts.select { |_, v| font_family?(v) }
        out['brand']['fonts'] = fonts.presence
        out['brand'].delete('fonts') if out['brand']['fonts'].nil?
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

    # Builds a profile from a short admin-entered form instead of a scan.
    #
    # A prospect with no website yet has nothing to scan, and the in-app design
    # showcase cannot be emailed to them — so without this the only way to demo
    # is creating a real company and Website record, which is exactly what the
    # profile model exists to avoid.
    def from_manual(attrs)
      attrs = attrs.to_h.with_indifferent_access
      profile = empty

      profile['brand'] = {
        'name' => attrs[:business_name].presence,
        'tagline' => attrs[:tagline].presence,
        'logo_url' => attrs[:logo_url].presence,
        'colors' => { 'primary' => attrs[:primary_color].presence }.compact.presence,
        'fonts' => { 'heading' => attrs[:font].presence, 'body' => attrs[:font].presence }.compact.presence
      }.compact

      profile['contact'] = {
        'phone' => attrs[:phone].presence,
        'email' => attrs[:email].presence,
        'address' => attrs[:address].presence
      }.compact

      hero = {
        'headline' => attrs[:headline].presence,
        'subhead' => attrs[:subhead].presence
      }.compact
      profile['copy']['hero'] = [hero] if hero.present?

      about = { 'heading' => attrs[:about_heading].presence, 'body' => attrs[:about].presence }.compact
      profile['copy']['about'] = [about] if about['body'].present?

      profile['seo'] = {
        'title' => attrs[:business_name].presence,
        'description' => attrs[:tagline].presence
      }.compact

      profile['source'] = { 'entered_manually' => true, 'warnings' => [] }
      profile
    end

    def hex_colour?(value)
      /\A#?(?:[0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})\z/i.match?(value.to_s.strip)
    end

    # A CSS font-family value, not a description of one.
    #
    # Deliberately strict about length and punctuation rather than trying to
    # recognise real font names: the failure mode is a sentence, and no genuine
    # family name is 40 characters of prose with parentheses in it.
    # Leading quote allowed: '"Gill Sans", sans-serif' is a perfectly ordinary
    # font-family value.
    FONT_FAMILY = /\A["']?[A-Za-z0-9][A-Za-z0-9 '"\-,]{0,39}\z/
    FONT_PROSE = /\b(?:appears?|looks?|similar|possibly|likely|maybe|probably|unclear|some kind)\b/i

    def font_family?(value)
      value = value.to_s.strip
      return false if value.blank?
      return false if FONT_PROSE.match?(value)

      FONT_FAMILY.match?(value)
    end

    def slice_strings(hash, keys)
      return {} unless hash.is_a?(Hash)

      keys.index_with do |k|
        next nil unless hash[k].is_a?(String)

        value = hash[k].strip.presence
        value unless value.nil? || PLACEHOLDER_VALUE.match?(value)
      end.compact
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
            "process":         [{ "title": str, "description": str }],

            "product":         [{ "name": str, "model_number": str, "summary": str, "msrp": str }],
            "specs":           [{ "label": str, "value": str, "unit": str, "group": str }],
            "features":        [{ "title": str, "description": str, "icon_hint": str }],
            "options":         [{ "title": str, "description": str, "price": str }],
            "floorplan":       [{ "name": str, "beds": str, "baths": str, "sqft": str,
                                  "dimensions": str, "image_url": url }]
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
        - product/specs/features/options/floorplan describe a specific product
          (a home, a unit, a model). Fill them when the source is a product
          sheet or spec document; leave them out for a general dealer website.
          Keep spec labels and values exactly as written — "1,344" and "sq ft"
          stay separate, and a measurement is never rounded or converted.
      CONTRACT
    end
  end
end
