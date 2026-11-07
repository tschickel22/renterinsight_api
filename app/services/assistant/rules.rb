# frozen_string_literal: true

module Assistant
  # Checks every assistant text in code before it is sent (backlog E96). The
  # prompt asks for the same things; this is what makes them true.
  module Rules
    MAX_LENGTH = 320
    MAX_UNANSWERED = 3

    URL = %r{https?://|www\.|\b[a-z0-9-]+\.(com|net|org|io|co|us|biz|info|homes|app)\b}i
    # A payment, rate, down payment or approval stated as a figure. Truth in
    # Lending treats a payment figure in a sales message as a trigger for
    # disclosures we do not give, so the assistant never states one.
    MONEY = /\$\s?\d|\d+(\.\d+)?\s?%|\b\d{2,3}\s?(a|per|\/)\s?(mo|month)\b/i
    FINANCE_WORDS = /\b(per month|a month|monthly|\/mo|apr|interest|rate|down payment|approved|approval|pre-?qualif|credit score)\b/i

    module_function

    # nil when the text may be sent; otherwise the reason it may not.
    # allowed_urls: the only web addresses this text may carry (a home's own
    # page, on a number registered for links).
    def violation(text, allowed_urls: [])
      return 'empty' if text.to_s.strip.empty?
      return 'link' if without(text, allowed_urls).match?(URL)
      return 'finance_figure' if text.match?(MONEY) && text.match?(FINANCE_WORDS)
      return 'too_long' if text.length > MAX_LENGTH

      nil
    end

    def without(text, urls)
      Array(urls).reduce(text.to_s) { |t, u| u.present? ? t.gsub(u, ' ') : t }
    end

    # House style: no em or en dashes in anything a buyer reads.
    def tidy(text)
      text.to_s.gsub(/\s*[—–]\s*/, ', ').gsub(/\s+/, ' ').strip
    end

    # Quiet hours run in the dealer location's time zone, the best guess at the
    # buyer's. A reply to someone who texted in the last 10 minutes is fine.
    def quiet_now?(settings, location, last_inbound_at: nil)
      return false if last_inbound_at && last_inbound_at > 10.minutes.ago

      zone = ActiveSupport::TimeZone[location.try(:timezone).presence || 'America/Denver'] || Time.zone
      hour = Time.current.in_time_zone(zone).hour
      start = settings['quiet_start_hour'].to_i
      stop = settings['quiet_end_hour'].to_i
      start > stop ? (hour >= start || hour < stop) : (hour >= start && hour < stop)
    end
  end
end
