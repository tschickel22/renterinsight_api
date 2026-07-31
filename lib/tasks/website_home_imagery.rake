# frozen_string_literal: true

# Pulls real manufacturer home photography out of the ingested catalog and
# rehosts it on our S3, so the website templates can ship with actual homes
# instead of stock photos of somebody else's house.
#
# Sourced from the catalog we already ingest rather than scraped: these are the
# manufacturer's own marketing images for models our dealers actually sell.
#
#   bin/rails website:pull_home_imagery
#   bin/rails "website:pull_home_imagery[5]"   # per manufacturer
namespace :website do
  # Only hosts we know are the manufacturer's own. The catalog also holds
  # seeded Unsplash and localhost placeholders, and shipping a template with a
  # stock photo of an unrelated house is the problem we are trying to fix.
  REAL_IMAGE_HOSTS = %w[
    api.claytonhomes.com
    s7d9.scene7.com
    trove.b-cdn.net
    d132mt2yijm03y.cloudfront.net
    cavco.com
    cdn.cavco.com
  ].freeze

  # Clayton splits exteriors and floor plans by path segment; Champion labels
  # its renditions. Anything unclassified is treated as an exterior only if it
  # is clearly not a plan.
  EXTERIOR_HINT = %r{/ext/|exterior|elevation}i
  FLOORPLAN_HINT = %r{/flp/|floor-?plan|floorplan}i

  desc 'Rehost manufacturer exterior and floor-plan imagery to S3'
  task :pull_home_imagery, [:per_manufacturer] => :environment do |_t, args|
    per = (args[:per_manufacturer] || 3).to_i
    uploader = S3UploadService.new
    picked = Hash.new { |h, k| h[k] = { exteriors: [], floorplans: [] } }

    Vehicle.where.not(images: nil).find_each do |vehicle|
      brand = normalize_brand(vehicle.make)
      next if brand.nil?

      bucket = picked[brand]
      next if bucket[:exteriors].size >= per && bucket[:floorplans].size >= per

      urls = [vehicle.elevation_images, vehicle.images, vehicle.floor_plan_images]
             .flat_map { |v| extract_urls(v) }
             .select { |u| real_image?(u) }

      urls.each do |url|
        if FLOORPLAN_HINT.match?(url)
          bucket[:floorplans] << [url, vehicle.model] if bucket[:floorplans].size < per
        elsif EXTERIOR_HINT.match?(url) || !FLOORPLAN_HINT.match?(url)
          bucket[:exteriors] << [url, vehicle.model] if bucket[:exteriors].size < per
        end
      end
    end

    if picked.empty?
      abort 'No manufacturer imagery found. Has the catalog been ingested?'
    end

    results = Hash.new { |h, k| h[k] = { exteriors: [], floorplans: [] } }

    picked.each do |brand, sets|
      puts "\n#{brand}"
      sets.each do |kind, entries|
        entries.uniq { |url, _| url }.each do |url, model|
          uploaded = rehost(uploader, url, brand, kind)
          next if uploaded.nil?

          results[brand][kind] << { url: uploaded, model: model }
          puts "  #{kind.to_s.chomp('s')}: #{model.to_s[0, 32].ljust(32)} -> #{uploaded}"
        end
      end
    end

    puts "\n\n// Frontend constants:\n"
    puts JSON.pretty_generate(results)
  end

  def normalize_brand(make)
    case make.to_s
    when /clayton/i then 'clayton'
    when /\btru\b/i then 'tru'
    when /champion|skyline/i then 'champion'
    when /legacy/i then 'legacy'
    when /sunshine/i then 'sunshine'
    when /cavco/i then 'cavco'
    end
  end

  def extract_urls(value)
    Array(value).filter_map do |item|
      raw = item.is_a?(Hash) ? (item['url'] || item[:url]) : item
      raw.to_s.presence
    end
  end

  def real_image?(url)
    return false unless url.to_s.start_with?('http')

    host = begin
      URI.parse(url).host
    rescue StandardError
      nil
    end
    return false if host.blank?

    REAL_IMAGE_HOSTS.any? { |h| host == h || host.end_with?(".#{h}") }
  end

  def rehost(uploader, url, brand, kind)
    uri, = SiteProfiles::UrlGuard.validate!(url)
    response = Net::HTTP.get_response(uri)
    return nil unless response.is_a?(Net::HTTPSuccess)

    content_type = response['content-type'].to_s.split(';').first
    ext = { 'image/jpeg' => '.jpg', 'image/png' => '.png', 'image/webp' => '.webp' }[content_type]
    return nil if ext.nil?

    file = Struct.new(:body, :content_type, :original_filename) do
      def read = body
      def size = body.bytesize
      def path = original_filename
    end.new(response.body, content_type, "#{brand}-#{kind}#{ext}")

    uploader.upload(file, folder: "brand/homes/#{brand}")[:url]
  rescue StandardError => e
    warn "  skip #{url[0, 60]}: #{e.message}"
    nil
  end
end
