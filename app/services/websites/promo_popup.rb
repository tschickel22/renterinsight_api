# frozen_string_literal: true

module Websites
  # The site's popup: a flyer and/or a video shown to a visitor on the first page
  # of their visit, between a start and end date, until they choose Enter Site.
  #
  # The date window is decided in the visitor's browser, not here. Dealer pages
  # are cached at the edge and revalidated against the website record, which does
  # not change when a date passes, so a server-side check would keep serving a
  # finished popup from cache (or never start one) until somebody edited the site.
  # The payload therefore carries the dates and the dealer's time zone.
  class PromoPopup
    FIELDS = %w[enabled image_url video_url headline enter_label directions_address start_date end_date].freeze
    DEFAULT_ENTER_LABEL = 'Enter Site'

    class Invalid < StandardError; end

    # Cleans what the editor sent. Raises Invalid with a message a dealer can act on.
    def self.normalize(raw)
      raw = raw.to_h.stringify_keys.slice(*FIELDS)
      popup = {
        'enabled' => ActiveModel::Type::Boolean.new.cast(raw['enabled']) || false,
        'image_url' => url(raw['image_url'], 'Flyer'),
        'video_url' => url(raw['video_url'], 'Video link'),
        'headline' => raw['headline'].to_s.strip.first(120).presence,
        'enter_label' => raw['enter_label'].to_s.strip.first(30).presence,
        'directions_address' => raw['directions_address'].to_s.strip.first(200).presence,
        'start_date' => date(raw['start_date'], 'Start date'),
        'end_date' => date(raw['end_date'], 'End date')
      }

      if popup['start_date'] && popup['end_date'] && popup['end_date'] < popup['start_date']
        raise Invalid, 'The end date is before the start date.'
      end
      if popup['enabled'] && popup['image_url'].nil? && popup['video_url'].nil?
        raise Invalid, 'Add a flyer or a video link before turning the popup on.'
      end

      popup.compact.deep_stringify_keys
    end

    # What the live site receives, or nil when there is nothing to show now or later.
    def self.public_payload(website)
      popup = website.promo_popup.to_h
      return nil unless popup['enabled']
      return nil if popup['image_url'].blank? && popup['video_url'].blank?

      zone = time_zone(website)
      end_date = popup['end_date'].presence && Date.parse(popup['end_date'])
      # Safe to drop once it is over: a cached copy that still carries it is
      # filtered out by the browser on the same dates.
      return nil if end_date && end_date < Time.current.in_time_zone(zone).to_date

      popup.slice(*FIELDS).merge(
        'enter_label' => popup['enter_label'].presence || DEFAULT_ENTER_LABEL,
        'directions_url' => directions_url(popup['directions_address']),
        'time_zone' => zone
      ).compact
    rescue StandardError => e
      Rails.logger.warn("[Websites::PromoPopup] payload failed for #{website.id}: #{e.message}")
      nil
    end

    # Prefill for the editor's Get Directions field.
    def self.default_address(website)
      website.location&.full_address || website.company&.locations&.order(:id)&.first&.full_address
    end

    def self.directions_url(address)
      return nil if address.blank?

      "https://www.google.com/maps/dir/?api=1&destination=#{ERB::Util.url_encode(address)}"
    end

    def self.time_zone(website)
      website.location&.timezone.presence || website.company&.time_zone || 'America/New_York'
    end

    def self.url(value, label)
      value = value.to_s.strip
      return nil if value.empty?
      raise Invalid, "#{label} must be a web address starting with https://" unless value.match?(%r{\Ahttps?://\S+\z}i)

      value
    end

    def self.date(value, label)
      value = value.to_s.strip
      return nil if value.empty?

      Date.iso8601(value).iso8601
    rescue Date::Error
      raise Invalid, "#{label} is not a valid date."
    end

    private_class_method :url, :date
  end
end
