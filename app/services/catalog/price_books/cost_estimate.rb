# frozen_string_literal: true

module Catalog
  module PriceBooks
    # What reading a file should cost, shown before the admin starts. Rates
    # come from the Champion Topeka package (2026-09-29): about 6 cents per
    # price list page, 4 cents per standards sheet, and 0.15 cents per filled
    # spreadsheet row (the 2,000-option workbook cost about $3.50).
    module CostEstimate
      PDF_PAGE_USD = 0.06
      SPREADSHEET_ROW_USD = 0.0015
      UNKNOWN_FILE_USD = 0.25

      module_function

      def for_document(doc)
        return 0.0 if doc.kind == 'image'

        rows = doc.metadata['filled_rows']
        if rows
          rows.to_i * SPREADSHEET_ROW_USD
        elsif doc.page_count
          doc.page_count * PDF_PAGE_USD
        else
          UNKNOWN_FILE_USD
        end
      end

      def for_documents(docs)
        docs.sum { |d| for_document(d) }.round(2)
      end
    end
  end
end
