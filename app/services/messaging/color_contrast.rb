# frozen_string_literal: true

module Messaging
  # WCAG relative luminance and contrast, used to pick text and accent colours that stay
  # legible against whatever background a tenant has configured.
  #
  # Email templates cannot adapt after the fact: there is no CSS that rescues dark text on a
  # dark band once the message is in someone's inbox. Anything painted on a tenant-supplied
  # colour has to be chosen at render time against that colour, which is what this does.
  #
  # Deliberately limited to colours. A logo is an image and its artwork colours are not
  # knowable from a URL, so nothing here can promise a logo is visible. See the note on
  # BlockRenderer::DEFAULT_HEADER_BACKGROUND.
  module ColorContrast
    LIGHT_TEXT = '#ffffff'
    DARK_TEXT  = '#111827'
    LIGHT_MUTED_TEXT = '#d1d5db'
    DARK_MUTED_TEXT  = '#6b7280'

    # Below this ratio two colours read as the same block of colour at a glance. Well under
    # the WCAG 4.5:1 text threshold on purpose: this guards decorative elements such as the
    # accent bar, where the goal is "visibly a separate thing" rather than "readable".
    MIN_DECORATIVE_CONTRAST = 1.4

    module_function

    # @return [Array<Float>, nil] r, g, b in 0..1, or nil if the string is not a hex colour
    def parse(hex)
      value = hex.to_s.strip.delete_prefix('#')
      value = value.chars.map { |c| c * 2 }.join if value.length == 3
      return nil unless value.match?(/\A[0-9a-f]{6}\z/i)

      value.scan(/../).map { |pair| pair.to_i(16) / 255.0 }
    end

    # WCAG 2.1 relative luminance. Returns nil for an unparseable colour so callers can fall
    # back rather than treat a typo as black and flip every colour on the page.
    def relative_luminance(hex)
      rgb = parse(hex)
      return nil if rgb.nil?

      r, g, b = rgb.map { |c| c <= 0.03928 ? c / 12.92 : (((c + 0.055) / 1.055)**2.4) }
      (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    end

    def contrast_ratio(one, two)
      a = relative_luminance(one)
      b = relative_luminance(two)
      return nil if a.nil? || b.nil?

      lighter, darker = [a, b].max, [a, b].min
      (lighter + 0.05) / (darker + 0.05)
    end

    # True when a background is dark enough that light text belongs on it. An unparseable
    # colour is treated as light, because the default background is light and that keeps the
    # fallback consistent with what is actually rendered.
    def dark?(hex)
      luminance = relative_luminance(hex)
      return false if luminance.nil?

      luminance < 0.5
    end

    def readable_text_on(background)
      dark?(background) ? LIGHT_TEXT : DARK_TEXT
    end

    def muted_text_on(background)
      dark?(background) ? LIGHT_MUTED_TEXT : DARK_MUTED_TEXT
    end

    # The colour to actually paint, given the one that was asked for. Returns the fallback
    # when the requested colour would disappear into the background, which is what happens to
    # a white accent bar on a white header.
    def visible_against(color, background, fallback: nil)
      ratio = contrast_ratio(color, background)
      return fallback || readable_text_on(background) if ratio.nil? || ratio < MIN_DECORATIVE_CONTRAST

      color
    end
  end
end
