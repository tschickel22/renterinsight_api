# frozen_string_literal: true

module SiteProfiles
  # Runs a document scan end to end and writes the result onto a SiteContentProfile.
  #
  # The crawl counterpart is Orchestrator. They stay separate because almost
  # nothing a crawl does applies here — no robots check, no link discovery, no
  # vendor detection, no page prioritisation. What they share is the output
  # contract: a coerced profile, a schema_version, a report, and a status the
  # admin UI can poll. Folding documents into Orchestrator would mean threading
  # `if document?` through every one of those steps.
  class DocumentOrchestrator
    class DocumentUnavailableError < StandardError; end

    def initialize(profile_record, downloader: S3DownloadAdapter.new)
      @record = profile_record
      @downloader = downloader
      @warnings = []
    end

    def call
      @record.update!(status: 'fetching')
      bytes = load_document

      @record.update!(status: 'extracting')

      ingested = DocumentIngestor.new(
        bytes: bytes,
        filename: @record.document_filename,
        content_type: @record.document_content_type
      ).call

      @warnings.concat(ingested.warnings)

      profile, schema_warnings, usage = ProfileBuilder.new(
        company: @record.company, user: @record.created_by
      ).call(
        digests: ingested.digests,
        images: ingested.images,
        source_url: source_label,
        inventory_images: InventoryImagery.for_profile(@record)
      )

      @warnings.concat(schema_warnings)
      @warnings << product_content_warning if product_sections_empty?(profile)

      @record.update!(
        status: 'ready',
        profile: profile,
        schema_version: ProfileSchema::VERSION,
        rasterized_page_count: ingested.images.size,
        model_version: usage[:model_version],
        input_tokens: usage[:input_tokens],
        output_tokens: usage[:output_tokens],
        report: build_report(ingested)
      )

      import_page_images(ingested)
      @record
    rescue StandardError => e
      @record.update!(status: 'failed', error_message: e.message.truncate(500))
      raise
    end

    private

    def load_document
      bytes = @downloader.call(@record.document_s3_key)
      raise DocumentUnavailableError, 'The uploaded document could not be retrieved.' if bytes.blank?

      bytes
    end

    # Stands in for source_url, which is nil on a document profile. Keeps the
    # report and AiQueryLog rows legible without pretending a URL was scanned.
    def source_label
      "document://#{@record.document_filename}"
    end

    def product_sections_empty?(profile)
      ProfileSchema::PRODUCT_SECTIONS.all? { |s| Array(profile.dig('copy', s)).empty? }
    end

    # Said explicitly, because a product sheet that yielded no product content
    # otherwise looks identical to a sparse document — and the difference
    # decides whether the admin re-uploads or edits by hand.
    def product_content_warning
      'No product, spec or floor plan content was found in this document. ' \
        'It may be a general brochure rather than a product sheet.'
    end

    def build_report(ingested)
      {
        'source_kind' => 'document',
        'document_filename' => @record.document_filename,
        'page_count' => ingested.page_count,
        'pages_rendered' => ingested.images.size,
        'text_pages' => ingested.digests.count { |d| d.paragraphs.present? || d.headings.present? },
        'pages_scanned' => ingested.digests.map(&:url),
        'warnings' => @warnings.uniq
      }
    end

    # The rendered pages are the only imagery a document scan has — the source
    # PDF's embedded photos are not individually addressable the way a web
    # page's <img> tags are. Storing them as media means the projected landing
    # page can show the actual product sheet rather than a placeholder.
    def import_page_images(ingested)
      return if ingested.images.empty?

      urls = DocumentPageMediaImporter.new(@record).call(ingested.images)
      return if urls.empty?

      profile = @record.profile.to_h
      media = profile['media'].to_h
      # Appended, not assigned: the model may have named a hero from the page
      # content and that choice should win over positional order.
      media['gallery'] = (Array(media['gallery']) + urls).uniq.first(24)
      media['hero_images'] = (Array(media['hero_images']) + urls).uniq.first(12)
      profile['media'] = media

      @record.update!(profile: profile)
    rescue StandardError => e
      Rails.logger.warn("[SiteProfiles::DocumentOrchestrator] page image import failed: #{e.message}")
      @record.update!(
        report: @record.report.to_h.merge(
          'warnings' => (Array(@record.report['warnings']) +
            ['Rendered document pages could not be stored; the profile has text only.']).uniq
        )
      )
    end

    # Thin seam over S3 so the orchestrator can be tested without a bucket.
    class S3DownloadAdapter
      def call(s3_key)
        return nil if s3_key.blank?

        S3UploadService.new.download(s3_key)
      end
    end
  end
end
