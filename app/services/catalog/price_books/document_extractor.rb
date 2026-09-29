# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Extracts one uploaded file into import items. Re-running replaces that
    # file's items, so a retry never duplicates rows.
    class DocumentExtractor
      def initialize(document, client: ClaudeClient)
        @doc = document
        @book = document.price_book
        @client = client
      end

      def call
        return if @doc.kind == 'image'

        @doc.update!(extraction_status: 'running', extraction_error: nil)
        @book.import_items.where(document: @doc).delete_all
        recorder = Recorder.new(@book, client: @client)
        bytes = PrivateFiles.read(PrivateFiles.ref(@doc.storage_key, @doc.storage_bucket))

        if @doc.kind == 'order_form'
          WorkbookExtractor.new(@doc, bytes, recorder).call
        elsif File.extname(@doc.filename).downcase == '.pdf'
          PdfExtractor.new(@doc, bytes, recorder).call
        else
          raise ExtractionError, 'Only PDF and Excel files can be read.'
        end

        @doc.reload
        return if @doc.extraction_status == 'skipped'

        @doc.update!(extraction_status: 'extracted', extracted_at: Time.current,
                     metadata: @doc.metadata.merge('usage' => recorder.usage))
      rescue ExtractionError, ClaudeClient::Error, PrivateFiles::Forbidden, Aws::S3::Errors::ServiceError => e
        fail!(e.message.truncate(500))
      rescue StandardError => e
        Rails.logger.error("[PriceBooks] #{@doc.filename}: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        fail!("Unexpected error: #{e.message.truncate(300)}")
      end

      private

      # A half-read file would look complete in review, so its items go too.
      def fail!(message)
        @book.import_items.where(document: @doc).delete_all
        @doc.update!(extraction_status: 'failed', extraction_error: message)
      end
    end
  end
end
