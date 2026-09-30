# frozen_string_literal: true

module Catalog
  module PriceBooks
    # What reading a file should cost, shown before the admin starts. Rates
    # come from the Champion Topeka package on staging (2026-09-29): about 6
    # cents per price list page, 4 cents per standards sheet, and the full
    # 14-tab options workbook (3,287 filled rows) cost $5.98, so 0.18 cents a
    # row, rounded up to 0.2 so estimates err high.
    module CostEstimate
      PDF_PAGE_USD = 0.06
      SPREADSHEET_ROW_USD = 0.002
      UNKNOWN_FILE_USD = 0.25

      module_function

      def for_document(doc)
        return 0.0 if doc.kind == 'image'

        tabs = doc.metadata['tab_list']
        selected = doc.metadata['selected_tabs']
        rows = if tabs && selected
                 tabs.select { |t| selected.include?(t['name']) }.sum { |t| t['rows'].to_i }
               else
                 doc.metadata['filled_rows']
               end
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
