# frozen_string_literal: true

require 'roo'

module Catalog
  module PriceBooks
    # The tabs of an options workbook, shown before anything is read so the
    # admin decides what to pay for. The Champion Topeka workbook has 14 tabs:
    # current forms, 2022 copies of forms that also appear as "2023 ...", a
    # tab marked DISREGARD, another plant's list. Obvious skips come
    # pre-unticked; everything else is the admin's call.
    module TabInventory
      YEAR = /\b(20\d{2})\b/
      NOISE = /\b(20\d{2}|sales order form|order form|options?|champion|topeka|and upgrades|hud|mod)\b/i

      module_function

      # @return [Array<Hash>] one per tab: name, rows, price_cells, year,
      #   header, estimate_usd, suggest_skip, reason
      def for_bytes(filename, bytes)
        ext = File.extname(filename).downcase
        Tempfile.create(['tabs', ext.presence || '.xlsx'], binmode: true) do |tmp|
          tmp.write(bytes)
          tmp.flush
          book = ext == '.csv' ? Roo::CSV.new(tmp.path) : Roo::Excelx.new(tmp.path)
          tabs = book.sheets.map { |name| describe(name, book.sheet(name)) }
          suggest(tabs)
        end
      end

      def describe(name, sheet)
        return { 'name' => name, 'rows' => 0, 'price_cells' => 0, 'year' => nil, 'header' => '' } unless sheet.first_row

        rows = cells = 0
        (sheet.first_row..sheet.last_row).each do |r|
          row = sheet.row(r)
          next if row.compact.empty?

          rows += 1
          cells += row.count { |v| v.is_a?(Numeric) && WorkbookExtractor::PRICE_RANGE.cover?(v.abs) }
        end
        header = (sheet.first_row..[sheet.first_row + 3, sheet.last_row].min)
                 .flat_map { |r| sheet.row(r).compact.map { |v| v.to_s.gsub(/<[^>]+>/, ' ') } }.join(' ').squish[0, 200]
        year = (name[YEAR, 1] || header[YEAR, 1])&.to_i
        { 'name' => name, 'rows' => rows, 'price_cells' => cells, 'year' => year, 'header' => header,
          'estimate_usd' => (rows * CostEstimate::SPREADSHEET_ROW_USD).round(2) }
      end

      # Pre-untick a tab marked to disregard, and a form that appears again
      # under a later year. The year comes from the header when the tab name
      # has none ("DGAE - HUD" is headed "2022 DGAE HUD"; "2023 DGAE HUD" is
      # the newer copy).
      def suggest(tabs)
        tabs.each do |t|
          t['suggest_skip'] = false
          if t['rows'].zero?
            t['suggest_skip'] = true
            t['reason'] = 'empty'
          elsif t['header'].to_s.match?(/disregard|disregaurd|do not use/i)
            t['suggest_skip'] = true
            t['reason'] = 'marked to disregard'
          end
        end

        tabs.each do |t|
          next if t['suggest_skip'] || t['year'].nil?

          key = form_key(t['name'])
          newer = tabs.find do |o|
            o != t && !o['suggest_skip'] && o['year'].to_i > t['year'] && form_key(o['name']) == key && key.present?
          end
          next unless newer

          t['suggest_skip'] = true
          t['reason'] = "#{t['year']} copy; \"#{newer['name']}\" is #{newer['year']}"
        end
        tabs
      end

      # "DGAE - HUD" and "2023 DGAE HUD" are the same form.
      def form_key(name)
        name.to_s.gsub(NOISE, ' ').downcase.gsub(/[^a-z0-9]/, '')
      end

      def default_selection(tabs)
        tabs.reject { |t| t['suggest_skip'] }.map { |t| t['name'] }
      end
    end
  end
end
