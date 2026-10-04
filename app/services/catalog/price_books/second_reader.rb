# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Reads again the page rows the first pass was unsure of, asking only for
    # those model numbers. Agreement settles the row; disagreement puts both
    # readings in front of the admin.
    class SecondReader
      FIELDS = { 'net_base_price' => 'net_base_price', 'beds' => 'beds', 'baths' => 'baths',
                 'width_ft' => 'box_width_ft', 'length_ft' => 'box_length_ft' }.freeze

      def initialize(book, client: ClaudeClient)
        @book = book
        @recorder = Recorder.new(book, client: client)
      end

      def call
        items = @book.import_items.pending.where(item_type: 'variant_price').where('flags ? :f', f: 'read_uncertain').to_a
        items.reject! { |i| i.payload['second_read'].present? }
        return 0 if items.empty?

        @book.update_columns(metadata: @book.metadata.merge('review_usage_base' => @book.metadata['review_usage'] || {}))

        items.group_by { |i| [i.catalog_price_book_document_id, i.source_ref['page']] }.each do |(doc_id, page), group|
          doc = @book.documents.find_by(id: doc_id) or next
          bytes = PrivateFiles.read(PrivateFiles.ref(doc.storage_key, doc.storage_bucket))
          page_pdf = single_page(bytes, page.to_i)
          numbers = group.map { |i| i.payload['model_number_as_printed'].presence || i.payload['model_number'] }
          r = @recorder.claude(content: [{ type: 'document', source: { type: 'base64', media_type: 'application/pdf',
                                                                         data: Base64.strict_encode64(page_pdf) } },
                                         { type: 'text', text: "Read only these rows, slowly and carefully: #{numbers.join(', ')}." }],
                               tool: Tools::PRICE_LIST, system: Tools::SYSTEM)
          rows = Array(r[:input]['rows']).index_by { |row| Catalog::ModelNumber.normalize(row['model_number']) }
          group.each do |item|
            row = rows[item.payload['model_number']]
            second = row ? FIELDS.to_h { |ours, theirs| [ours, row[theirs]] } : {}
            agrees = row.present? && row['uncertain'].blank? &&
                     FIELDS.keys.all? { |k| second[k].nil? || second[k].to_f == item.payload[k].to_f }
            item.update!(payload: item.payload.merge('second_read' => second.merge('agrees' => agrees)))
          end
        end
        items.size
      rescue ClaudeClient::Error, PrivateFiles::Forbidden, ExtractionError => e
        Rails.logger.warn("[PriceBooks] second read skipped: #{e.message}")
        0
      end

      private

      def single_page(bytes, page)
        pdf = CombinePDF.parse(bytes, allow_optional_content: true)
        return bytes if page < 1 || page > pdf.pages.size

        out = CombinePDF.new
        out << pdf.pages[page - 1]
        out.to_pdf
      rescue StandardError
        bytes
      end
    end
  end
end
