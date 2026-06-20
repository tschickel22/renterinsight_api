# frozen_string_literal: true

require 'open-uri'

module Catalog
  # Downloads source images (respecting crawl_delay) and mirrors them into the
  # existing website-assets S3 bucket via S3UploadService, returning the image
  # records with `local_url` populated. Re-downloads only when the source URL
  # changes (caller compares against the stored record).
  #
  # Best-effort: a failed download leaves local_url nil and keeps source_url, so
  # the home still renders from the origin CDN.
  class ImageArchiver
    def initialize(crawl_delay: 0, folder: 'catalog')
      @crawl_delay = crawl_delay.to_i
      @folder      = folder
      @uploader    = S3UploadService.new
    end

    # @param images [Array<Hash>] NormalizedHome image records
    # @return [Array<Hash>] same records with local_url filled where possible
    def archive(images)
      Array(images).map do |img|
        record = img.dup
        next record if record['local_url'].present?

        source_url = record['source_url'] || record['url']
        next record if source_url.blank?

        sleep(@crawl_delay) if @crawl_delay.positive? && !Rails.env.test?
        local = upload(source_url, record['alt'])
        record['local_url'] = local if local
        record
      end
    end

    private

    def upload(source_url, alt)
      io = URI.parse(source_url).open(
        'User-Agent' => Adapters::BaseAdapter::USER_AGENT,
        read_timeout: 30
      )
      file = ActionDispatch::Http::UploadedFile.new(
        tempfile: io,
        filename: descriptive_filename(source_url, alt),
        type:     io.content_type
      )
      @uploader.upload(file, folder: @folder)[:url]
    rescue StandardError => e
      Rails.logger.warn "[Catalog::ImageArchiver] download failed for #{source_url}: #{e.class}: #{e.message}"
      nil
    end

    # Mirror a descriptive name into the filename (also used as alt text).
    def descriptive_filename(source_url, alt)
      base = alt.to_s.parameterize.presence || File.basename(URI.parse(source_url).path, '.*').parameterize
      ext  = File.extname(URI.parse(source_url).path).presence || '.jpg'
      "#{base}#{ext}"
    rescue StandardError
      "catalog-image#{File.extname(source_url.to_s).presence || '.jpg'}"
    end
  end
end
