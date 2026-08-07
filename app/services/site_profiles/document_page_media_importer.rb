# frozen_string_literal: true

module SiteProfiles
  # Stores a document's rendered pages as WebsiteMedia so the projected landing
  # page can show the actual product sheet.
  #
  # The crawl counterpart is AssetImporter, which re-hosts images it found by
  # URL. A PDF has no addressable images — its photography is embedded in the
  # page stream — so what gets stored is the rendered page itself. That is
  # enough for a gallery, a hero backdrop, or a "view the spec sheet" panel,
  # which is what these are actually used for.
  class DocumentPageMediaImporter
    FOLDER = 'site-profiles/documents'

    # A Struct rather than an uploaded file, so S3UploadService treats a
    # rendered page exactly like a browser upload. Mirrors AssetImporter::Downloaded.
    Rendered = Struct.new(:body, :content_type, :original_filename) do
      def read = body
      def size = body.bytesize
      def path = original_filename
    end

    def initialize(profile_record, uploader: S3UploadService.new, logger: Rails.logger)
      @record = profile_record
      @uploader = uploader
      @logger = logger
    end

    # @param images [Array<Hash>] DocumentRasterizer output
    # @return [Array<String>] public URLs, in page order
    def call(images)
      Array(images).filter_map { |img| store(img) }
    end

    private

    def store(img)
      bytes = Base64.decode64(img['data_base64'].to_s)
      return nil if bytes.blank?

      filename = "page-#{img['page']}.jpg"
      rendered = Rendered.new(bytes, img['content_type'].presence || 'image/jpeg', filename)

      # Deterministic key: re-running a scan should overwrite the same objects
      # rather than pile up a fresh set of pages on every attempt.
      uploaded = @uploader.upload(
        rendered,
        folder: "#{FOLDER}/#{@record.id}",
        key: "#{FOLDER}/#{@record.id}/#{filename}"
      )
      return nil if uploaded.blank? || uploaded[:url].blank?

      create_media_record(uploaded, rendered)
      uploaded[:url]
    rescue StandardError => e
      @logger.warn("[SiteProfiles::DocumentPageMediaImporter] page #{img['page']}: #{e.message}")
      nil
    end

    def create_media_record(uploaded, rendered)
      WebsiteMedia.create!(
        company_id: @record.company_id,
        name: "#{@record.document_filename.presence || 'document'} — #{rendered.original_filename}",
        url: uploaded[:url],
        s3_key: uploaded[:key],
        s3_bucket: ENV['AWS_S3_BUCKET'].presence,
        mime_type: rendered.content_type,
        file_size: rendered.size,
        file_type: :image
      )
    rescue StandardError => e
      # The upload succeeded; a bookkeeping failure must not lose the image.
      @logger.warn("[SiteProfiles::DocumentPageMediaImporter] media row: #{e.message}")
    end
  end
end
