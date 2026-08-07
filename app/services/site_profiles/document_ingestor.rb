# frozen_string_literal: true

module SiteProfiles
  # Turns an uploaded document into the same inputs a crawl produces.
  #
  # Fetcher's job for a URL; this is Fetcher's job for a file. It emits
  # PageDigest::Digest structs so ProfileBuilder needs no special case, plus the
  # rasterised pages that let the model see the layout rather than infer it from
  # recovered text.
  #
  # Supported: PDF (text + rendered pages), images (rendered only), plain text.
  # Anything else is rejected with a message rather than half-read.
  class DocumentIngestor
    class UnsupportedDocumentError < StandardError; end

    PDF_TYPES = %w[application/pdf].freeze
    # The four Claude accepts as image content blocks.
    IMAGE_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze
    TEXT_TYPES = %w[text/plain text/markdown].freeze

    # Mirrors Campaigns::AiBuilder's text budget. Beyond this the prompt cost
    # stops buying accuracy.
    MAX_TEXT_CHARS = 50_000

    # A line this short that does not end a sentence reads as a heading on a
    # spec sheet — section labels, product names, spec keys.
    HEADING_MAX_CHARS = 70

    Result = Struct.new(:digests, :images, :warnings, :page_count, keyword_init: true)

    def initialize(bytes:, filename:, content_type: nil)
      @bytes = bytes.to_s
      @filename = filename.presence || 'document'
      @content_type = content_type.to_s.downcase.presence || sniff_content_type
    end

    def call
      raise UnsupportedDocumentError, 'The uploaded file is empty.' if @bytes.blank?

      case @content_type
      when *PDF_TYPES   then ingest_pdf
      when *IMAGE_TYPES then ingest_image
      when *TEXT_TYPES  then ingest_text
      else
        raise UnsupportedDocumentError,
              "#{@content_type.presence || 'This file type'} is not supported. Upload a PDF, an image, or a text file."
      end
    end

    private

    # Content type from the client is a hint, not a fact — browsers send
    # application/octet-stream for plenty of ordinary uploads. Magic bytes win.
    def sniff_content_type
      head = @bytes[0, 12].to_s.dup.force_encoding('ASCII-8BIT')
      return 'application/pdf' if head.start_with?('%PDF')
      return 'image/jpeg'      if head[0, 3].unpack('C*') == [0xFF, 0xD8, 0xFF]
      return 'image/png'       if head[0, 8].unpack('C*') == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
      return 'image/gif'       if head.start_with?('GIF87a', 'GIF89a')
      return 'image/webp'      if head[0, 4] == 'RIFF' && head[8, 4] == 'WEBP'

      'text/plain' if likely_text?
    end

    def likely_text?
      sample = @bytes[0, 2048].to_s
      sample.force_encoding('UTF-8').valid_encoding? && !sample.include?("\x00")
    end

    # --- PDF -------------------------------------------------------------

    def ingest_pdf
      warnings = []
      pages_text = extract_pdf_text(warnings)
      images = DocumentRasterizer.call(@bytes)

      if images.empty?
        warnings << 'Document pages could not be rendered to images, so the design was read from text only. ' \
                    'Layout, photography and colour will not carry over.'
      end

      if pages_text.empty? && images.empty?
        raise UnsupportedDocumentError,
              'No text or images could be read from this PDF. It may be encrypted or damaged.'
      end

      # A scanned-paper PDF, or one whose text layer failed to parse, has images
      # and no text. The vision pass carries it, but say so — extraction quality
      # differs enough to matter.
      if pages_text.all?(&:blank?)
        warnings << 'This PDF contains no selectable text; content was read from the page images alone.'
      end

      # Pad to the rendered page count. Without this a PDF whose text layer
      # failed produces zero digests, and ProfileBuilder is handed nothing at
      # all to describe — the images would be attached to an empty page list.
      page_count = [pages_text.size, images.size].max
      texts = Array.new(page_count) { |i| pages_text[i].to_s }

      Result.new(
        digests: texts.each_with_index.map { |text, i| digest_for(text, page: i + 1) },
        images: images,
        warnings: warnings,
        page_count: page_count
      )
    end

    def extract_pdf_text(warnings)
      require 'pdf-reader'
      reader = PDF::Reader.new(StringIO.new(@bytes))
      budget = MAX_TEXT_CHARS

      reader.pages.first(DocumentRasterizer::MAX_PAGES).map do |page|
        # Stop adding text once the budget is spent, but keep the page slot —
        # `break []` here would discard the pages already read.
        next '' if budget <= 0

        text = page.text.to_s.squeeze("\n").strip
        budget -= text.length
        text
      end
    rescue StandardError => e
      warnings << "Text extraction failed (#{e.class}); reading the document from its page images instead."
      []
    end

    # --- Image -----------------------------------------------------------

    # An uploaded image is one page with no text. There is nothing to extract
    # deterministically, so the vision pass is the whole scan.
    def ingest_image
      Result.new(
        digests: [digest_for('', page: 1)],
        images: [{
          'filename' => @filename,
          'content_type' => @content_type,
          'page' => 1,
          'data_base64' => Base64.strict_encode64(@bytes)
        }],
        warnings: [],
        page_count: 1
      )
    end

    # --- Plain text ------------------------------------------------------

    def ingest_text
      text = @bytes.dup.force_encoding('UTF-8')
                   .encode('UTF-8', invalid: :replace, undef: :replace, replace: '')[0, MAX_TEXT_CHARS]

      raise UnsupportedDocumentError, 'The uploaded file contains no readable text.' if text.strip.blank?

      Result.new(
        digests: [digest_for(text, page: 1)],
        images: [],
        warnings: ['Plain text upload — no layout, imagery or colour to carry over.'],
        page_count: 1
      )
    end

    # --- Shared ----------------------------------------------------------

    # ProfileBuilder reads digests structurally, so a document page has to look
    # like a fetched page. The synthetic document:// URL keeps `source.pages_scanned`
    # meaningful and makes it obvious in the report that this was not a crawl.
    def digest_for(text, page:)
      headings, paragraphs = split_lines(text)

      PageDigest::Digest.new(
        url: "document://#{@filename}#page-#{page}",
        title: page == 1 ? File.basename(@filename, '.*').tr('_-', '  ').squish : nil,
        meta_description: nil,
        og_image: nil,
        headings: headings,
        paragraphs: paragraphs,
        images: [],
        background_images: [],
        links: [],
        forms: [],
        iframes: [],
        scripts: { external: [], inline: [] },
        # Not client-rendered — this is a document. Anything above the
        # likely_client_rendered? threshold avoids a misleading warning.
        text_ratio: 1.0
      )
    end

    def split_lines(text)
      lines = text.to_s.split("\n").map(&:squish).reject(&:blank?)
      headings = []
      paragraphs = []

      lines.each do |line|
        if line.length <= HEADING_MAX_CHARS && !line.end_with?('.', '!', '?')
          headings << { level: 'h2', text: line.truncate(200) }
        else
          paragraphs << line.truncate(500)
        end
      end

      [headings.first(60), paragraphs.first(60)]
    end
  end
end
