# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Price lists, standards sheets and announcements delivered as PDF.
    #
    # Price lists go one page at a time: sent whole, a two-page list lost its
    # entire second page in Phase 0, and reading per page fixed it. Where the
    # PDF has a text layer, the model numbers on it are the answer key; any the
    # model missed are asked for once more, and anything still missing is
    # reported on the document.
    class PdfExtractor
      def initialize(document, bytes, sink)
        @doc = document
        @bytes = bytes
        @sink = sink
        @texts = Classifier.pdf_text(bytes)
      end

      def call
        kind = @doc.kind
        kind = classify if kind == 'unknown'
        @doc.update!(kind: kind)

        case kind
        when 'price_list' then extract_price_list
        when 'standards' then extract_standards
        when 'announcement' then extract_announcement
        else
          @doc.update!(extraction_status: 'skipped', extraction_error: "Not a price list, standards sheet or announcement (#{kind})")
        end
      end

      private

      def scanned?
        @texts.join.strip.empty?
      end

      def classify
        r = @sink.claude(content: [pdf_block(page_bytes.first || @bytes),
                                   { type: 'text', text: 'What kind of document is this?' }],
                         tool: Tools::CLASSIFY, system: Tools::SYSTEM, max_tokens: 500)
        r[:input]['kind'].presence || 'unknown'
      end

      def extract_price_list
        missing_overall = []
        page_bytes.each_with_index do |page, i|
          expected = Checks.model_numbers_in(@texts[i])
          header, rows = read_page(page, "Extract every row of this price list page. Some pages print two tables side by side; read both.")

          found = rows.map { |r| Catalog::ModelNumber.normalize(r['model_number']) }
          missed = expected - found
          if missed.any?
            _, more = read_page(page, "These model numbers are printed on this page and were not captured: #{missed.join(', ')}. " \
                                      'Record exactly those rows.')
            rows += more.reject { |r| found.include?(Catalog::ModelNumber.normalize(r['model_number'])) }
            found = rows.map { |r| Catalog::ModelNumber.normalize(r['model_number']) }
            missing_overall.concat(expected - found)
          end

          rows.each { |row| write_price_row(row, header, page: i + 1) }
        end

        meta = @doc.metadata.merge('pages_read' => page_bytes.size, 'scanned' => scanned?,
                                   'missing_model_numbers' => missing_overall.uniq)
        @doc.update!(metadata: meta)
      end

      def read_page(page, instruction)
        r = @sink.claude(content: [pdf_block(page), { type: 'text', text: instruction }], tool: Tools::PRICE_LIST, system: Tools::SYSTEM)
        input = r[:input].deep_stringify_keys
        [input.except('rows'), Array(input['rows'])]
      end

      def write_price_row(row, header, page:)
        row = row.deep_stringify_keys
        printed = row['model_number'].to_s.strip
        normalized = Catalog::ModelNumber.normalize(printed)
        mn = Catalog::ModelNumber.parse(normalized)

        flags = Checks.model_code_flags(row) + Checks.adder_flags(row)
        flags << 'model_number_normalized' if printed.upcase != normalized
        flags << 'scanned_source' if scanned?
        flags << 'read_uncertain' if row['uncertain'].present?

        @sink.item(
          document: @doc, item_type: 'variant_price', flags: flags,
          source_ref: { 'document_id' => @doc.id, 'page' => page },
          payload: {
            'model_number' => normalized, 'model_number_as_printed' => printed,
            'model_name' => row['model_name'], 'plant' => header['plant'], 'series' => header['series'],
            'building_code' => mn.building_code || header['building_code'],
            'effective_date' => header['effective_date'], 'fob' => header['fob'],
            'width_ft' => row['box_width_ft'], 'length_ft' => row['box_length_ft'],
            'beds' => row['beds'], 'baths' => row['baths'], 'home_type' => row['home_type'],
            'net_base_price' => row['net_base_price'], 'required_adders' => Array(row['required_adders']),
            'total_base_price' => row['total_base_price'], 'uncertain' => row['uncertain']
          }.compact
        )
      end

      def extract_standards
        r = @sink.claude(content: [pdf_block(@bytes), { type: 'text', text:
          'Record every standard feature, grouped by the category headers. The sheet is laid out in columns; ' \
          'keep each item under its own column header. Join items that wrap onto a second line.' }],
                         tool: Tools::STANDARDS, system: Tools::SYSTEM, max_tokens: 16_000)
        input = r[:input].deep_stringify_keys
        text = normalize_text(@texts.join(' '))
        position = 0
        Array(input['categories']).each do |cat|
          Array(cat['items']).each do |name|
            position += 1
            flags = []
            flags << 'not_verbatim' if text.present? && !text.include?(normalize_text(name))
            @sink.item(document: @doc, item_type: 'standard_feature', flags: flags,
                       source_ref: { 'document_id' => @doc.id },
                       payload: { 'series' => input['series'], 'building_code' => input['building_code'],
                                  'category' => cat['name'], 'name' => name, 'position' => position }.compact)
          end
        end
      end

      def extract_announcement
        r = @sink.claude(content: [pdf_block(@bytes), { type: 'text', text: 'Record each product change.' }],
                         tool: Tools::PRODUCT_CHANGES, system: Tools::SYSTEM, max_tokens: 8_000)
        Array(r[:input]['changes']).each do |c|
          @sink.item(document: @doc, item_type: 'product_change', flags: [],
                     source_ref: { 'document_id' => @doc.id }, payload: c.to_h.deep_stringify_keys)
        end
      end

      # One single-page PDF per page; the whole file if it cannot be split.
      def page_bytes
        @page_bytes ||= begin
          pdf = CombinePDF.parse(@bytes, allow_optional_content: true)
          pdf.pages.map do |p|
            single = CombinePDF.new
            single << p
            single.to_pdf
          end
        rescue StandardError
          [@bytes]
        end
      end

      def pdf_block(bytes)
        { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: Base64.strict_encode64(bytes) } }
      end

      def normalize_text(s) = s.to_s.downcase.gsub(/[^a-z0-9]/, '')
    end
  end
end
