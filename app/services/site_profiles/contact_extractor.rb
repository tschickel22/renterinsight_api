# frozen_string_literal: true

module SiteProfiles
  # Pulls phone, email and address off the pages deterministically.
  #
  # These live in the header and footer — exactly the chrome PageDigest strips
  # before reading prose — so asking the model for them yields "Tyler, Texas"
  # and no phone number at all. A dealer demo without a phone number is broken,
  # and tel:/mailto: links are unambiguous, so this is a parse and not a guess.
  class ContactExtractor
    # US-centric on purpose: (903) 566-1000, 903-566-1000, 903.566.1000.
    PHONE_TEXT = /\(?\b(\d{3})\)?[-.\s]?(\d{3})[-.\s]?(\d{4})\b/

    # Street line followed by city/state/zip, which is how dealers write it.
    ADDRESS = /\d{3,6}\s+[\w.\s]{3,40}(?:St|Street|Ave|Avenue|Rd|Road|Hwy|Highway|Blvd|Boulevard|Dr|Drive|Ln|Lane|Pkwy|Way)\b[\w\s,.#-]{0,60}?,?\s*[A-Z]{2}\s+\d{5}/i

    def initialize(digests, pages_html: {})
      @digests = Array(digests)
      @pages_html = pages_html
    end

    def call
      {
        'phone' => phone,
        'email' => email,
        'address' => address,
        'social' => social
      }.compact.reject { |_, v| v.respond_to?(:empty?) && v.empty? }
    end

    private

    def all_links
      @all_links ||= @digests.flat_map { |d| Array(d.links) }
    end

    def hrefs
      @hrefs ||= all_links.filter_map { |l| (l[:href] || l['href']).to_s }
    end

    # A tel: link is the site telling us its number outright.
    def phone
      from_link = hrefs.find { |h| h.downcase.start_with?('tel:') }
      return normalize_phone(from_link.sub(/\Atel:/i, '')) if from_link

      match = combined_text.match(PHONE_TEXT)
      match && normalize_phone(match[0])
    end

    def normalize_phone(raw)
      digits = raw.to_s.gsub(/\D/, '').sub(/\A1(?=\d{10}\z)/, '')
      return nil unless digits.length == 10

      "(#{digits[0, 3]}) #{digits[3, 3]}-#{digits[6, 4]}"
    end

    def email
      from_link = hrefs.find { |h| h.downcase.start_with?('mailto:') }
      candidate = from_link&.sub(/\Amailto:/i, '')&.split('?')&.first
      candidate ||= combined_text[/[\w.+-]+@[\w-]+\.[\w.-]+/]
      return nil if candidate.blank?
      # Skip the boilerplate addresses every WordPress theme ships with.
      return nil if candidate.match?(/example\.com|sentry|wixpress|@2x/i)

      candidate.strip.downcase
    end

    def address
      combined_text[ADDRESS]&.squish
    end

    SOCIAL_HOSTS = {
      'facebook' => /facebook\.com/i,
      'instagram' => /instagram\.com/i,
      'youtube' => /youtube\.com|youtu\.be/i,
      'linkedin' => /linkedin\.com/i,
      'tiktok' => /tiktok\.com/i,
      'twitter' => /twitter\.com|x\.com/i
    }.freeze

    def social
      SOCIAL_HOSTS.each_with_object({}) do |(name, pattern), out|
        hit = hrefs.find { |h| h.match?(pattern) }
        out[name] = hit if hit
      end
    end

    # Headings and paragraphs carry the address when it is not a link; the raw
    # HTML is the fallback for footers rendered as plain text.
    def combined_text
      @combined_text ||= begin
        digest_text = @digests.flat_map do |d|
          Array(d.headings).map { |h| h[:text] } + Array(d.paragraphs) +
            Array(d.links).map { |l| l[:label] }
        end.compact.join("\n")

        [digest_text, @pages_html.values.join("\n")].join("\n")
      end
    end
  end
end
