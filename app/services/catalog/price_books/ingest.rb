# frozen_string_literal: true

require 'zip'

module Catalog
  module PriceBooks
    # Takes what a platform admin dropped on a price book (loose files or a ZIP
    # of them) and stores each file once in the private bucket as a
    # CatalogPriceBookDocument. Dealer net pricing is confidential, so nothing
    # here touches the public upload bucket.
    class Ingest
      MAX_FILE_BYTES = 50.megabytes
      MAX_ZIP_ENTRIES = 200
      SKIP = %r{(\A|/)(__MACOSX|\.DS_Store|Thumbs\.db|\._)}

      Result = Struct.new(:added, :duplicates, :skipped, keyword_init: true)

      def initialize(price_book)
        @book = price_book
      end

      # @param files [Array<ActionDispatch::Http::UploadedFile>]
      def call(files)
        result = Result.new(added: [], duplicates: [], skipped: [])
        Array(files).each do |file|
          name = file.original_filename.to_s
          bytes = file.read
          if zip?(name, bytes)
            unzip(bytes, result)
          else
            add(name, bytes, file.content_type, result)
          end
        end
        result
      end

      private

      def zip?(name, bytes)
        name.downcase.end_with?('.zip') || bytes.to_s.byteslice(0, 4) == "PK\x03\x04".b && !office_file?(name)
      end

      # .xlsx and .docx are ZIP containers too; only a real archive gets unpacked.
      def office_file?(name)
        name.downcase.match?(/\.(xlsx|xlsm|docx|pptx)\z/)
      end

      def unzip(bytes, result)
        count = 0
        Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
          zip.each do |entry|
            next if entry.directory? || utf8(entry.name).match?(SKIP)

            count += 1
            if count > MAX_ZIP_ENTRIES
              result.skipped << { filename: utf8(entry.name), reason: "more than #{MAX_ZIP_ENTRIES} files in the archive" }
              next
            end
            if entry.size > MAX_FILE_BYTES
              result.skipped << { filename: utf8(entry.name), reason: 'larger than 50 MB' }
              next
            end
            add(File.basename(entry.name), entry.get_input_stream.read, nil, result, archive_path: entry.name)
          end
        end
      rescue Zip::Error => e
        result.skipped << { filename: 'archive', reason: "could not be opened: #{e.message}" }
      end

      def add(name, bytes, content_type, result, archive_path: nil)
        # ZIP entry names arrive as raw bytes; Windows zips may not even be UTF-8.
        name = utf8(name)
        archive_path = utf8(archive_path) if archive_path
        if bytes.bytesize > MAX_FILE_BYTES
          result.skipped << { filename: name, reason: 'larger than 50 MB' }
          return
        end

        checksum = Digest::SHA256.hexdigest(bytes)
        existing = @book.documents.find_by(checksum_sha256: checksum)
        if existing
          result.duplicates << existing
          return
        end

        kind = Classifier.guess(name, bytes)
        tabs = kind == 'order_form' ? (TabInventory.for_bytes(name, bytes) rescue nil) : nil
        key = "catalog/price-books/#{@book.id}/#{checksum[0, 12]}_#{safe(name)}"
        PrivateFiles.put(bytes, key: key, content_type: content_type.presence || Classifier.content_type(name))

        result.added << @book.documents.create!(
          filename: name,
          content_type: content_type.presence || Classifier.content_type(name),
          byte_size: bytes.bytesize,
          checksum_sha256: checksum,
          storage_bucket: PrivateFiles.bucket,
          storage_key: key,
          kind: kind,
          page_count: Classifier.page_count(name, bytes),
          metadata: { 'archive_path' => archive_path, 'filled_rows' => Classifier.filled_rows(name, bytes),
                      'tab_list' => tabs, 'selected_tabs' => tabs && TabInventory.default_selection(tabs) }.compact
        )
      end

      def utf8(s)
        s.to_s.dup.force_encoding(Encoding::UTF_8).scrub('_')
      end

      def safe(name)
        base = File.basename(name, '.*').parameterize(separator: '_').presence || 'file'
        "#{base[0, 80]}#{File.extname(name).downcase}"
      end
    end
  end
end
