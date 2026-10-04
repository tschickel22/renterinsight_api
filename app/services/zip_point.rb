# frozen_string_literal: true

require 'net/http'

# Where a US zip code is, for "factories near this dealer". Locations store
# only a zip, and nothing else in the app geocodes, so the zip's center comes
# from zippopotam.us (free, no key) and is kept a month. nil when it cannot be
# found or the service is down; callers fall back to matching the state.
module ZipPoint
  module_function

  EARTH_MILES = 3958.8

  # => [latitude, longitude] or nil
  def call(zip)
    zip = zip.to_s[/\A\s*(\d{5})/, 1]
    return nil unless zip

    Rails.cache.fetch("zip_point:#{zip}", expires_in: 30.days, skip_nil: true) { lookup(zip) }
  end

  def lookup(zip)
    uri = URI("https://api.zippopotam.us/us/#{zip}")
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 3) { |h| h.get(uri.request_uri) }
    return nil unless res.is_a?(Net::HTTPSuccess)

    place = Array(JSON.parse(res.body)['places']).first
    place && [place['latitude'].to_f, place['longitude'].to_f]
  rescue StandardError => e
    Rails.logger.warn("ZipPoint #{zip}: #{e.class} #{e.message}")
    nil
  end

  # Great-circle miles between two [lat, lng] points.
  def miles(a, b)
    lat1, lng1, lat2, lng2 = [*a, *b].map { |d| d.to_f * Math::PI / 180 }
    h = (Math.sin((lat2 - lat1) / 2)**2) + (Math.cos(lat1) * Math.cos(lat2) * (Math.sin((lng2 - lng1) / 2)**2))
    2 * EARTH_MILES * Math.asin(Math.sqrt(h))
  end
end
