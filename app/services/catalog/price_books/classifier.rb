# frozen_string_literal: true

module Catalog
  module PriceBooks
    # A first guess at what each file is, from its name and text. Spreadsheets
    # are order forms; the workbook extractor sorts their tabs itself. A PDF
    # with no text layer (a copier scan) cannot be guessed from text, so it is
    # left `unknown` for the extractor to classify with vision.
    module Classifier
      MODEL_NUMBER = /\b\d{4}[HM][0-9A-Z]{5}\b/
      IMAGE_EXT = %w[.jpg .jpeg .png .gif .webp .heic .tif .tiff].freeze

      module_function

      def guess(name, bytes)
        ext = File.extname(name).downcase
        return 'order_form' if %w[.xlsx .xlsm .xls .csv].include?(ext)
        return 'image' if IMAGE_EXT.include?(ext)
        # Our own structured catalog file (StructuredExtractor).
        return 'price_list' if StructuredExtractor.structured?(name, bytes)
        return 'unknown' unless ext == '.pdf'

        page_text = pdf_text(bytes).first(2).join(' ')
        return 'unknown' if page_text.strip.empty?

        text = "#{name} #{page_text}".downcase
        # A page of model numbers is a price list even when its notes mention
        # "Modular Standards", as the Aspire modular list does.
        if page_text.scan(MODEL_NUMBER).size >= 3 then 'price_list'
        elsif text.include?('standard') then 'standards'
        elsif text.match?(/announce|product change|discontinu/) then 'announcement'
        elsif page_text.match?(MODEL_NUMBER) || text.match?(/pric(e|ing)|net base/) then 'price_list'
        else 'unknown'
        end
      end

      # Text per page, or [] for a scan or an unreadable PDF.
      def pdf_text(bytes)
        reader = PDF::Reader.new(StringIO.new(bytes))
        reader.pages.map { |p| p.text.to_s }
      rescue StandardError
        []
      end

      def page_count(name, bytes)
        return nil unless File.extname(name).downcase == '.pdf'

        PDF::Reader.new(StringIO.new(bytes)).page_count
      rescue StandardError
        nil
      end

      # Rows with any value across every tab, for the cost estimate.
      def filled_rows(name, bytes)
        ext = File.extname(name).downcase
        return nil unless %w[.xlsx .xlsm .csv].include?(ext)

        Tempfile.create(['estimate', ext], binmode: true) do |tmp|
          tmp.write(bytes)
          tmp.flush
          book = ext == '.csv' ? Roo::CSV.new(tmp.path) : Roo::Excelx.new(tmp.path)
          book.sheets.sum do |s|
            sheet = book.sheet(s)
            next 0 unless sheet.first_row

            (sheet.first_row..sheet.last_row).count { |r| sheet.row(r).any? { |v| v.present? } }
          end
        end
      rescue StandardError
        nil
      end

      def content_type(name)
        Marcel::MimeType.for(name: name) || 'application/octet-stream'
      end
    end
  end
end
