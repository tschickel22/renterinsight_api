# frozen_string_literal: true

require 'digest'

# Rehosts real manufacturer home photography from the catalog we already ingest
# onto our S3, so the website templates ship with actual manufactured homes
# instead of stock photos of site-built houses.
#
# IDEMPOTENT. The S3 key is a hash of the source URL, so re-running reuses the
# existing object rather than uploading a second copy. The first version used
# timestamped names and littered the bucket every run.
#
# Writes a manifest to db/website_home_imagery.json. Regenerating the frontend
# constants reads that file — it does not require re-downloading anything.
#
#   bin/rails website:pull_home_imagery          # 3 of each kind per brand
#   bin/rails "website:pull_home_imagery[5]"
#   FORCE=1 bin/rails website:pull_home_imagery  # re-upload even if present
namespace :website do
  MANIFEST_PATH = Rails.root.join('db/website_home_imagery.json')

  # Only the manufacturers' own hosts. The catalog also holds seeded Unsplash
  # and localhost placeholders, and shipping a template with a stock photo of
  # an unrelated house is the problem being fixed.
  REAL_IMAGE_HOSTS = %w[
    api.claytonhomes.com
    s7d9.scene7.com
    trove.b-cdn.net
    d132mt2yijm03y.cloudfront.net
    cavco.com
    cdn.cavco.com
  ].freeze

  # Clayton splits by path segment (/ext/, /int/, /flp/); Champion labels its
  # renditions (-kitchen-1, -exterior). Order matters: interior and floorplan
  # are checked before exterior, since exterior is the fallback.
  CLASSIFIERS = {
    floorplans: %r{/flp/|floor-?plan}i,
    interiors: %r{/int/|kitchen|living|bedroom|bath|interior}i,
    exteriors: %r{/ext/|exterior|elevation}i
  }.freeze

  desc 'Rehost manufacturer exterior, interior and floor-plan imagery to S3'
  task :pull_home_imagery, [:per_kind] => :environment do |_t, args|
    per = (args[:per_kind] || 3).to_i
    force = ENV['FORCE'].present?
    uploader = S3UploadService.new

    picked = Hash.new { |h, k| h[k] = Hash.new { |i, j| i[j] = [] } }

    Vehicle.find_each do |vehicle|
      brand = normalize_brand(vehicle.make)
      next if brand.nil?

      bucket = picked[brand]
      next if CLASSIFIERS.keys.all? { |kind| bucket[kind].size >= per }

      image_urls(vehicle).each do |url|
        kind = classify(url)
        next if kind.nil? || bucket[kind].size >= per
        next if bucket[kind].any? { |u, _| u == url }

        bucket[kind] << [url, vehicle.model]
      end
    end

    abort 'No manufacturer imagery found. Has the catalog been ingested?' if picked.empty?

    manifest = load_manifest
    uploaded_count = 0
    reused_count = 0

    picked.sort.each do |brand, kinds|
      puts "\n#{brand}"
      kinds.each do |kind, entries|
        entries.each do |url, model|
          key = deterministic_key(brand, kind, url)

          if !force && (cached = manifest.dig(brand, kind.to_s)&.find { |e| e['source'] == url })
            reused_count += 1
            puts "  reuse #{kind.to_s.chomp('s').ljust(9)} #{model.to_s[0, 28]}"
            next
          end

          hosted = rehost(uploader, url, key, force: force)
          next if hosted.nil?

          manifest[brand] ||= {}
          manifest[brand][kind.to_s] ||= []
          manifest[brand][kind.to_s].reject! { |e| e['source'] == url }
          manifest[brand][kind.to_s] << { 'source' => url, 'url' => hosted, 'model' => model }
          uploaded_count += 1
          puts "  upload #{kind.to_s.chomp('s').ljust(9)} #{model.to_s[0, 28]}"
        end
      end
    end

    File.write(MANIFEST_PATH, "#{JSON.pretty_generate(manifest)}\n")
    puts "\n#{uploaded_count} uploaded, #{reused_count} reused. Manifest: #{MANIFEST_PATH}"
    puts 'Regenerate frontend constants with: bin/rails website:print_home_imagery'
  end

  desc 'Print the frontend constants from the imagery manifest (no uploads)'
  task print_home_imagery: :environment do
    manifest = load_manifest
    abort "No manifest at #{MANIFEST_PATH}. Run website:pull_home_imagery first." if manifest.empty?

    %w[exteriors interiors floorplans].each do |kind|
      puts "\n// #{kind}"
      manifest.each do |brand, kinds|
        Array(kinds[kind]).each do |entry|
          puts "  { src: '#{entry['url']}', manufacturer: '#{brand.capitalize}', model: #{entry['model'].to_s.inspect} },"
        end
      end
    end
  end

  def load_manifest
    return {} unless File.exist?(MANIFEST_PATH)

    JSON.parse(File.read(MANIFEST_PATH))
  rescue JSON::ParserError
    {}
  end

  # Same source URL -> same key -> one object, however often this runs.
  def deterministic_key(brand, kind, url)
    ext = File.extname(URI.parse(url).path).presence || '.jpg'
    ext = '.jpg' unless %w[.jpg .jpeg .png .webp].include?(ext.downcase)
    "brand/homes/#{brand}/#{kind}-#{Digest::SHA256.hexdigest(url)[0, 16]}#{ext}"
  rescue StandardError
    "brand/homes/#{brand}/#{kind}-#{Digest::SHA256.hexdigest(url)[0, 16]}.jpg"
  end

  def image_urls(vehicle)
    [vehicle.elevation_images, vehicle.images, vehicle.champion_images, vehicle.floor_plan_images]
      .flat_map { |col| Array(col).filter_map { |i| (i.is_a?(Hash) ? (i['url'] || i[:url]) : i).to_s.presence } }
      .select { |u| real_image?(u) }
      .uniq
  end

  def classify(url)
    CLASSIFIERS.each { |kind, pattern| return kind if pattern.match?(url) }
    # Unlabelled images on a manufacturer CDN are overwhelmingly exteriors, but
    # only claim that when nothing else matched.
    :exteriors
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

  def rehost(uploader, url, key, force: false)
    return public_url(key) if !force && uploader.exists?(key)

    uri, = SiteProfiles::UrlGuard.validate!(url)
    response = Net::HTTP.get_response(uri)
    return nil unless response.is_a?(Net::HTTPSuccess)

    content_type = response['content-type'].to_s.split(';').first
    return nil unless %w[image/jpeg image/png image/webp].include?(content_type)

    file = Struct.new(:body, :content_type, :original_filename) do
      def read = body
      def size = body.bytesize
      def path = original_filename
    end.new(response.body, content_type, File.basename(key))

    uploader.upload(file, key: key)[:url]
  rescue StandardError => e
    warn "  skip #{url[0, 60]}: #{e.message}"
    nil
  end

  def public_url(key)
    bucket = ENV['AWS_S3_BUCKET'].presence || 'renterinsight-website-assets-staging'
    region = ENV['AWS_REGION'].presence || 'us-west-2'
    "https://#{bucket}.s3.#{region}.amazonaws.com/#{key}"
  end
end
