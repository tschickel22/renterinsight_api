# frozen_string_literal: true

require 'open-uri'
require 'digest'

module Catalog
  # Mirrors manufacturer imagery into our own S3 bucket so listings stop
  # hot-linking three third-party CDNs (CloudFront, Bunny, Clayton). If a
  # manufacturer reorganises or expires a URL, every dealer listing pointing at
  # it goes blank; archived copies do not.
  #
  # CONTENT-ADDRESSED, SO RE-RUNS ARE FREE.
  # The key is a hash of the source URL, matching the scheme
  # lib/tasks/website_home_imagery.rake uses. Without this, S3UploadService's
  # default random key means every nightly run re-downloads and re-uploads every
  # image to a fresh URL — unbounded storage growth, and a changed `local_url`
  # on every vehicle every night.
  #
  # Existence is resolved with ONE paginated listing per run rather than a HEAD
  # per image, because a full catalog is several thousand images.
  #
  # Best-effort throughout: a failed download leaves local_url nil and keeps
  # source_url, so the home still renders from the origin CDN. Archiving must
  # never be able to fail a run that otherwise succeeded.
  class ImageArchiver
    FOLDER      = 'catalog/homes'
    HASH_LENGTH = 16
    ALLOWED_EXT = %w[.jpg .jpeg .png .webp .gif].freeze
    DEFAULT_EXT = '.jpg'

    # Manufacturer sites answer 200 with a placeholder rather than 404 when an
    # image is missing — Kabco returned 348-byte PNGs for two of the first three
    # we tried, alongside a genuine 698 KB one. Archiving those is worse than
    # hot-linking: it freezes an error into the listing AND replaces the source
    # URL that might have worked on a later attempt. Treat anything implausibly
    # small as a failed fetch so source_url survives and the next run retries.
    MIN_BYTES = 2_048
    # Politeness between DOWNLOADS only; skipped images cost nothing.
    #
    # NOT zero. A full Kabco run with no delay fired ~1,100 requests at their
    # WordPress site as fast as the network allowed and was rate-limited into
    # the ground: 184 archived, 839 refused with 429. These are manufacturer
    # marketing sites, not CDNs built for that.
    DEFAULT_DELAY = 1

    # Once a host starts refusing, continuing is both pointless and rude — the
    # run above kept going for 839 more requests after the first 429. Stop
    # archiving for the remainder of the run instead, and leave source_url on
    # everything untouched so nothing is lost but time.
    RATE_LIMIT_TRIP = 3

    Result = Struct.new(:archived, :reused, :failed, :skipped, :rate_limited, keyword_init: true)

    attr_reader :result

    def initialize(crawl_delay: DEFAULT_DELAY, folder: FOLDER, uploader: nil)
      @crawl_delay = crawl_delay.to_i
      @folder      = folder
      @uploader    = uploader || S3UploadService.new
      @result      = Result.new(archived: 0, reused: 0, failed: 0, skipped: 0, rate_limited: false)
      @consecutive_rate_limits = 0
    end

    # S3UploadService falls back to a bucket literally named "...-staging" when
    # AWS_S3_BUCKET is unset. For transient uploads that is merely untidy; here
    # it is not, because the archived URL is written into every vehicle row.
    # Production imagery would be permanently pinned to the staging bucket, and
    # whatever retention or clean-up applies there would govern live dealer
    # listings.
    #
    # Scoped to this service on purpose: the dozen existing upload paths keep
    # their current behaviour, so nothing that works today can start failing.
    def misconfigured_bucket?
      Rails.env.production? && @uploader.bucket_name.to_s.include?('staging')
    end

    def bucket_warning
      "Refusing to archive: production is pointed at #{@uploader.bucket_name.inspect}. " \
        'Set AWS_S3_BUCKET to the production bucket first — archived URLs are stored ' \
        'on every vehicle, so this is not something a later env change can undo.'
    end

    # @param images [Array<Hash>] NormalizedHome image records
    # @return [Array<Hash>] same records with local_url filled where possible
    def archive(images)
      if misconfigured_bucket?
        Rails.logger.error "[Catalog::ImageArchiver] #{bucket_warning}"
        @result.skipped += Array(images).size
        return Array(images)
      end

      Array(images).map do |img|
        record = img.dup
        source_url = record['source_url'] || record['url']

        if record['local_url'].present? || source_url.blank?
          @result.skipped += 1
          next record
        end

        # Backed off for this host — leave the rest alone rather than adding to
        # the pile of refusals.
        if @result.rate_limited
          @result.skipped += 1
          next record
        end

        key = key_for(source_url)

        if existing_keys.include?(key)
          # Already in the bucket from an earlier run — no download, no upload.
          record['local_url'] = public_url(key)
          @result.reused += 1
          next record
        end

        local = upload(source_url, key)
        if local
          record['local_url'] = local
          existing_keys << key
          @result.archived += 1
        else
          @result.failed += 1
        end
        record
      end
    end

    # Same source URL -> same key -> one object, however often this runs.
    def key_for(source_url)
      "#{@folder}/#{Digest::SHA256.hexdigest(source_url.to_s)[0, HASH_LENGTH]}#{extension_for(source_url)}"
    end

    private

    # One listing per archiver instance, paginated. Cheaper by orders of
    # magnitude than a HEAD request per image once a catalog is a few thousand
    # strong, and it is the reason S3UploadService#list_files had to learn to
    # page.
    def existing_keys
      @existing_keys ||= begin
        Set.new(@uploader.list_files(@folder))
      rescue StandardError => e
        Rails.logger.warn "[Catalog::ImageArchiver] listing failed, falling back to per-object " \
                          "checks: #{e.class}: #{e.message}"
        Set.new
      end
    end

    # Split out so specs never reach a CDN.
    def open_source(source_url)
      URI.parse(source_url).open(
        'User-Agent' => Adapters::BaseAdapter::USER_AGENT,
        read_timeout: 30
      )
    end

    def upload(source_url, key)
      sleep(@crawl_delay) if @crawl_delay.positive? && !Rails.env.test?

      io    = open_source(source_url)
      bytes = io.read
      io.close if io.respond_to?(:close)

      if bytes.to_s.bytesize < MIN_BYTES
        Rails.logger.warn "[Catalog::ImageArchiver] #{source_url} returned only " \
                          "#{bytes.to_s.bytesize} bytes — treating as a placeholder, not archiving"
        return nil
      end

      file = ActionDispatch::Http::UploadedFile.new(
        tempfile: StringIO.new(bytes),
        filename: File.basename(key),
        type:     io.respond_to?(:content_type) ? io.content_type : nil
      )
      url = @uploader.upload(file, folder: @folder, key: key)[:url]
      @consecutive_rate_limits = 0
      url
    rescue StandardError => e
      if rate_limited?(e)
        @consecutive_rate_limits += 1
        if @consecutive_rate_limits >= RATE_LIMIT_TRIP
          @result.rate_limited = true
          Rails.logger.warn "[Catalog::ImageArchiver] #{URI.parse(source_url).host} is refusing " \
                            "requests (#{@consecutive_rate_limits} consecutive 429s) — backing off " \
                            'for the rest of this run. Raise image_crawl_delay on the source.'
        end
      else
        @consecutive_rate_limits = 0
      end

      Rails.logger.warn "[Catalog::ImageArchiver] archive failed for #{source_url}: #{e.class}: #{e.message}"
      nil
    end

    def rate_limited?(error)
      error.is_a?(OpenURI::HTTPError) && error.message.to_s.start_with?('429')
    end

    # Manufacturer URLs carry cache-busting queries and the odd uppercase
    # extension; anything unrecognised becomes .jpg rather than leaking a query
    # string into an S3 key.
    def extension_for(source_url)
      ext = File.extname(URI.parse(source_url.to_s).path.to_s).downcase
      ALLOWED_EXT.include?(ext) ? ext : DEFAULT_EXT
    rescue StandardError
      DEFAULT_EXT
    end

    def public_url(key)
      "https://#{@uploader.bucket_name}.s3.#{@uploader.region}.amazonaws.com/#{key}"
    end
  end
end
