# frozen_string_literal: true

# Keeps every dealer website domain on the Turnstile widget that guards lead forms.
#
# A Turnstile widget only runs on the hostnames listed on it (an entry covers its
# subdomains). The platform widget listed only our own domains, so on
# www.easyhomesource.com (2026-10-20) the check showed "Unable to connect to website", no
# token was ever issued, and the API rejected every submission on a form flagged
# captcha_required. Leads were being dropped and nothing on our side noticed.
#
# Adds only. Staging and production share the widget, so removing an entry when one
# environment deletes a domain could break a live dealer in the other. A stale entry costs
# a slot; a missing one costs leads.
class TurnstileDomainService
  include HTTParty
  base_uri 'https://api.cloudflare.com/client/v4'

  class Error < StandardError; end
  class Full < Error; end

  # Hostnames per widget on Cloudflare's non-Enterprise plans.
  MAX_DOMAINS = 10

  def self.configured?
    ENV['TURNSTILE_SITE_KEY'].present? && account_id.present? && api_token.present?
  end

  def self.account_id
    ENV['CLOUDFLARE_ACCOUNT_ID'].presence || Rails.application.credentials.dig(:cloudflare, :account_id)
  end

  def self.api_token
    ENV['CLOUDFLARE_API_TOKEN'].presence || Rails.application.credentials.dig(:cloudflare, :api_token)
  end

  # The entry a hostname needs. www is dropped so the bare domain is covered too, which is
  # where a forwarded apex lands visitors before redirecting them.
  def self.entry_for(hostname)
    hostname.to_s.downcase.strip.chomp('.').delete_prefix('www.')
  end

  # Best effort for callers that must not fail on it (adding a domain), but never silent:
  # a dealer whose domain is missing from the widget loses every form lead.
  def self.allow_with_alert(hostname)
    return :not_configured unless configured?

    new.allow!(hostname)
  rescue Error => e
    Rails.logger.error "[Turnstile] Could not add #{hostname} to the lead form widget: #{e.message}"
    Ops::Alert.notify!(
      "turnstile:#{entry_for(hostname)}",
      "Lead forms will fail on #{hostname}",
      "#{hostname} could not be added to the Turnstile widget (#{e.message}). Forms that " \
      "require the bot check reject every submission there until it is. Add " \
      "#{entry_for(hostname)} under Turnstile, hostnames, in Cloudflare.",
      every: 1.day
    )
    :failed
  end

  # => :already_covered or :added. Raises Full when the widget has no room left.
  def allow!(hostname)
    entry = self.class.entry_for(hostname)
    raise Error, 'No hostname given' if entry.blank?

    widget = fetch_widget
    domains = Array(widget[:domains]).map(&:downcase)
    return :already_covered if domains.any? { |d| entry == d || entry.end_with?(".#{d}") }
    raise Full, "the widget already lists #{domains.size} of #{MAX_DOMAINS} hostnames" if domains.size >= MAX_DOMAINS

    update_widget(widget, domains + [entry])
    Rails.logger.info "[Turnstile] Added #{entry} to the lead form widget"
    :added
  end

  private

  def path
    "/accounts/#{self.class.account_id}/challenges/widgets/#{ENV['TURNSTILE_SITE_KEY']}"
  end

  def fetch_widget
    handle(self.class.get(path, headers: headers))
  end

  # PUT replaces the widget, so every setting is sent back as it was; only domains change.
  def update_widget(widget, domains)
    body = widget.slice(:name, :mode, :bot_fight_mode, :region, :clearance_level, :offlabel, :ephemeral_id)
                 .merge(domains: domains)
    handle(self.class.put(path, headers: headers, body: body.to_json))
  end

  def handle(response)
    parsed = JSON.parse(response.body.to_s, symbolize_names: true) rescue {}
    return parsed[:result] || {} if response.success? && parsed[:success] != false

    message = Array(parsed[:errors]).map { |e| e[:message] }.compact.join(', ').presence ||
              "HTTP #{response.code}"
    raise Error, message
  end

  def headers
    { 'Authorization' => "Bearer #{self.class.api_token}", 'Content-Type' => 'application/json' }
  end
end
