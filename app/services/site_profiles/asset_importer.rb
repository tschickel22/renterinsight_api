# frozen_string_literal: true

require 'net/http'

module SiteProfiles
  # Copies a scanned site's imagery onto our S3 and rewrites the profile to
  # point at our copies.
  #
  # Without this an imported site hotlinks the client's old host: it breaks the
  # day they cancel that hosting, it can be blocked by referrer rules at any
  # time, and every page view we serve costs them bandwidth. A demo can survive
  # hotlinking; a committed site cannot.
  #
  # Fetches go through the same UrlGuard as the crawl — an image URL is just as
  # much attacker-controlled input as a page URL.
  class AssetImporter
    MAX_BYTES = 12 * 1024 * 1024
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 20
    FOLDER = 'site-imports'

    ALLOWED_TYPES = {
      'image/jpeg' => '.jpg', 'image/jpg' => '.jpg', 'image/png' => '.png',
      'image/webp' => '.webp', 'image/gif' => '.gif', 'image/avif' => '.avif'
    }.freeze

    Result = Struct.new(:profile, :imported, :skipped, :warnings, keyword_init: true)

    # A Struct rather than an uploaded file, so S3UploadService can treat a
    # downloaded image exactly like a browser upload.
    Downloaded = Struct.new(:body, :content_type, :original_filename) do
      def read = body
      def size = body.bytesize
      def path = original_filename
    end

    def initialize(profile_record, uploader: S3UploadService.new, logger: Rails.logger)
      @record = profile_record
      @uploader = uploader
      @logger = logger
      @map = {}
      @warnings = []
      @skipped = 0
    end

    # Rewrites media.* and any block image URLs in place on the profile.
    def call
      profile = @record.profile.deep_dup
      media = profile['media'].to_h

      %w[logo og_image].each do |key|
        next if media[key].blank?

        rehosted = import(media[key])
        media[key] = rehosted if rehosted
      end

      %w[hero_images gallery].each do |key|
        media[key] = Array(media[key]).filter_map { |url| import(url) || nil }
      end

      profile['media'] = media
      profile['brand'] = rehost_brand(profile['brand'].to_h)

      @record.update!(profile: profile)

      # Count successes, not attempts — a failed import lands in the map as nil.
      Result.new(
        profile: profile,
        imported: @map.values.compact.uniq.size,
        skipped: @skipped,
        warnings: @warnings.uniq
      )
    end

    private

    def rehost_brand(brand)
      return brand if brand['logo_url'].blank?

      rehosted = import(brand['logo_url'])
      rehosted ? brand.merge('logo_url' => rehosted) : brand
    end

    # Returns our URL, or nil when the image could not be brought across. Nil
    # means "drop it": a broken image on a client's preview is worse than one
    # fewer photo.
    def import(url)
      return @map[url] if @map.key?(url)
      return url if already_ours?(url)

      downloaded = download(url)
      if downloaded.nil?
        @skipped += 1
        return @map[url] = nil
      end

      uploaded = @uploader.upload(downloaded, folder: "#{FOLDER}/#{@record.id}")
      create_media_record(uploaded, downloaded, url)
      @map[url] = uploaded[:url]
    rescue StandardError => e
      @logger.warn("[SiteProfiles::AssetImporter] #{url} failed: #{e.class}: #{e.message}")
      @warnings << "Could not copy #{File.basename(URI.parse(url).path)}."
      @skipped += 1
      @map[url] = nil
    end

    def already_ours?(url)
      bucket = ENV['AWS_S3_BUCKET'].presence
      bucket.present? && url.to_s.include?(bucket)
    end

    def download(url)
      uri, = UrlGuard.validate!(url)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = Fetcher::USER_AGENT
      response = http.request(request)

      return nil unless response.is_a?(Net::HTTPSuccess)

      content_type = response['content-type'].to_s.split(';').first&.strip
      extension = ALLOWED_TYPES[content_type]
      unless extension
        @warnings << "Skipped a non-image asset (#{content_type.presence || 'unknown type'})."
        return nil
      end

      body = response.body.to_s
      if body.bytesize > MAX_BYTES
        @warnings << "Skipped #{File.basename(uri.path)} — larger than #{MAX_BYTES / 1024 / 1024}MB."
        return nil
      end
      return nil if body.empty?

      Downloaded.new(
        body: body,
        content_type: content_type,
        original_filename: filename_for(uri, extension)
      )
    rescue UrlGuard::BlockedUrlError
      @warnings << 'Skipped an image on a non-public address.'
      nil
    rescue StandardError => e
      @logger.warn("[SiteProfiles::AssetImporter] download #{url}: #{e.class}: #{e.message}")
      nil
    end

    def filename_for(uri, extension)
      base = File.basename(uri.path.to_s, '.*').presence || 'image'
      "#{base.parameterize.presence || 'image'}#{extension}"
    end

    # Recorded against the company (not a website — none exists yet) so the
    # media library and any later cleanup can see them.
    def create_media_record(uploaded, downloaded, source_url)
      WebsiteMedia.create!(
        company_id: @record.company_id,
        name: downloaded.original_filename,
        url: uploaded[:url],
        s3_key: uploaded[:key],
        s3_bucket: ENV['AWS_S3_BUCKET'].presence,
        mime_type: downloaded.content_type,
        file_size: downloaded.size,
        file_type: :image
      )
    rescue StandardError => e
      # The upload succeeded; a bookkeeping failure must not lose the image.
      @logger.warn("[SiteProfiles::AssetImporter] media row for #{source_url}: #{e.message}")
    end
  end
end
