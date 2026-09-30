# frozen_string_literal: true

require 'roo'

module Catalog
  module PriceBooks
    # A factory options workbook (.xlsx or .csv). Each tab is one of:
    #   - announcements: product changes, read by the model
    #   - a master option list (a header row with "Option No."): read directly,
    #     no model involved, since the columns are already a table
    #   - an order form: two or three options per row, section headers mixed
    #     in, cost and retail columns in either order. Read by the model in
    #     chunks of rows, every price then checked against its cell.
    #
    # Coverage is measured, not assumed: any price cell no option points at is
    # sent back for one repair pass. Phase 0 showed repair passes get the
    # numbers right but can file them under the wrong package, so those items
    # are flagged for the reviewer.
    class WorkbookExtractor
      CHUNK_ROWS = 90
      CONTEXT_ROWS = 12
      HEADER_ROWS = 8
      # What counts as a price cell for coverage (Phase 0 rule): skips bed and
      # bath counts and the markup multiplier, keeps every dollar figure.
      PRICE_RANGE = (5...200_000).freeze
      STANDARD_CELL = %r{\A(std|standard|incl(uded)?|n/?c|no charge)\.?\z}i

      ORDER_FORM_PROMPT = <<~SYS
        You turn manufactured home factory order forms into structured option data for human review.
        Record every priced option in ROWS TO EXTRACT, including STD items, and every color or finish selection.
        Two numbers next to an option are a dealer cost and a retail price. Decide which is which from the column headers and from the tab's markup multiplier (retail is about cost times the multiplier). Always give the cell reference each number came from.
        Size bands in descriptions (e.g. "<48' Box", "56'-64' Hitch", "SW", "Sect") go into applies_to. "IPO" and "T/O" mean in place of / throughout.
        A price table keyed by model or plan number belongs to the option named above it; record one option per row with applies_to.model_numbers.
        Mark the tab stale if it says to disregard it.
        Never invent a number that is not in a cell.
      SYS

      def initialize(document, bytes, sink)
        @doc = document
        @bytes = bytes
        @sink = sink
      end

      def call
        book = open_workbook
        summary = {}
        # Only the tabs the admin left ticked (TabInventory pre-unticks the
        # obvious skips). A file uploaded before tab picking reads everything.
        selected = @doc.metadata['selected_tabs']
        book.sheets.each do |name|
          if selected && !selected.include?(name)
            summary[name] = { 'kind' => 'skipped', 'reason' => 'not selected' }
            next
          end

          sheet = book.sheet(name)
          summary[name] = extract_sheet(name, sheet)
        end
        @doc.update!(metadata: @doc.metadata.merge('tabs' => summary))
      end

      private

      def open_workbook
        ext = File.extname(@doc.filename).downcase
        raise ExtractionError, 'Old .xls workbooks cannot be read. Save it as .xlsx and upload again.' if ext == '.xls'

        tmp = Tempfile.new(['price_book', ext.presence || '.xlsx'], binmode: true)
        tmp.write(@bytes)
        tmp.flush
        ext == '.csv' ? Roo::CSV.new(tmp.path) : Roo::Excelx.new(tmp.path)
      end

      def extract_sheet(name, sheet)
        grid = grid_rows(sheet)
        return { 'kind' => 'empty' } if grid.empty?

        if name.match?(/announc/i)
          extract_announcements(name, grid)
        elsif master_list?(sheet)
          extract_master_list(name, sheet)
        else
          extract_order_form(name, sheet, grid)
        end
      end

      # ---- order forms ------------------------------------------------------

      def extract_order_form(name, sheet, grid)
        header = grid.first(HEADER_ROWS)
        options = []
        colors = []
        markup = nil
        stale = nil

        grid.each_slice(CHUNK_ROWS).with_index do |slice, i|
          start = i * CHUNK_ROWS
          context = i.zero? ? [] : grid[[start - CONTEXT_ROWS, 0].max...start]
          input = read_chunk(name, header, context, slice, first: i.zero?)
          markup ||= input['markup_multiplier']
          stale ||= input['stale'] if input.dig('stale', 'is_stale')
          options.concat(Array(input['options']))
          colors.concat(Array(input['color_choices']))
        end

        if stale
          # The tab says to disregard it. Recorded on the document, not imported.
          return { 'kind' => 'order_form', 'stale' => true, 'reason' => stale['reason'] }
        end

        used = Set.new
        options.each { |o| used.merge(write_option(name, sheet, o, markup, used_cells: used)) }

        missed = price_cells(sheet) - used.to_a
        repaired = 0
        if missed.any?
          rows = missed.map { |ref| ref[/\d+/].to_i }.uniq
          slice = grid.select { |r, _| rows.include?(r) || rows.any? { |m| r.between?(m - 6, m) } }
          input = read_chunk(name, header, [], slice, repair: missed)
          Array(input['options']).each do |o|
            cells = write_option(name, sheet, o, markup, used_cells: used, extra_flags: ['label_needs_review'])
            repaired += 1 if cells.any?
            used.merge(cells)
          end
        end
        still_missed = price_cells(sheet) - used.to_a

        colors.each do |c|
          @sink.item(document: @doc, item_type: 'option', flags: [],
                     source_ref: { 'document_id' => @doc.id, 'sheet' => name, 'cells' => [c['cell']].compact },
                     payload: { 'kind' => 'color', 'tab' => name, 'group' => c['group'], 'name' => c['name'] }.compact)
        end

        { 'kind' => 'order_form', 'markup' => markup, 'options' => options.size, 'colors' => colors.size,
          'price_cells' => price_cells(sheet).size, 'repaired' => repaired, 'uncovered_cells' => still_missed.first(50) }
      end

      def read_chunk(name, header, context, slice, first: false, repair: nil)
        text = +"Worksheet \"#{name}\". Cells are listed as COLUMN+ROW=value. Values in adjacent columns on one row are often separate options side by side, each followed by its own price cells.\n\n"
        text << "TAB HEADER (for markup, title and date only):\n#{header.map(&:last).join("\n")}\n\n" unless first
        if context.any?
          text << "CONTEXT ROWS (already processed, do NOT record options from these, use only to know the current section):\n" \
                  "#{context.map(&:last).join("\n")}\n\n"
        end
        text << "These price cells were not captured yet: #{repair.join(', ')}. Record only the options they belong to.\n\n" if repair
        text << "ROWS TO EXTRACT:\n#{slice.map(&:last).join("\n")}"
        @sink.claude(content: [{ type: 'text', text: text }], tool: Tools::OPTIONS, system: ORDER_FORM_PROMPT)[:input].deep_stringify_keys
      end

      # Writes one option_price item. Returns the cells it accounts for.
      def write_option(tab, sheet, opt, markup, used_cells:, extra_flags: [])
        cost_cell = opt['dealer_cost_cell'].presence
        retail_cell = opt['retail_cell'].presence
        return [] if [cost_cell, retail_cell].compact.any? { |c| used_cells.include?(c) }

        flags = extra_flags.dup
        cost = grounded(sheet, cost_cell, opt['dealer_cost'], flags, 'cost')
        retail = grounded(sheet, retail_cell, opt['retail'], flags, 'retail')
        markup_flags, cost, retail = Checks.markup_check(cost, retail, markup)
        flags.concat(markup_flags)
        return [] if cost.nil? && retail.nil? && !opt['is_standard']

        # Credits (Omit Range, -$100) and no-charge options (2 Bedroom Option,
        # $0) are real prices. Only a blank cost with no retail to derive it
        # from is missing.
        flags << 'price_missing' if !opt['is_standard'] && cost.nil? && retail.nil?

        @sink.item(
          document: @doc, item_type: 'option_price', flags: flags.uniq,
          source_ref: { 'document_id' => @doc.id, 'sheet' => tab, 'cells' => [cost_cell, retail_cell].compact },
          payload: {
            'tab' => tab, 'section' => opt['section'], 'description' => opt['description'],
            'dealer_cost' => cost, 'suggested_retail' => retail, 'is_standard' => opt['is_standard'] == true,
            'markup' => markup, 'applies_to' => (opt['applies_to'] || {}).compact,
            'in_place_of' => opt['in_place_of'], 'package_items' => Array(opt['package_items']),
            'choices' => Array(opt['choices']), 'notes' => opt['notes']
          }.compact
        )
        [cost_cell, retail_cell].compact
      end

      # The cell's own value wins; a number the model wrote that is not in the
      # cell it named is flagged and dropped rather than trusted.
      def grounded(sheet, ref, value, flags, label)
        return nil if value.nil? && ref.nil?

        cell = ref && cell_value(sheet, ref)
        # "STD" / "Std" / "Included": a standard item, not a missing price.
        return nil if cell.is_a?(String) && cell.strip.match?(STANDARD_CELL)

        if cell.is_a?(Numeric)
          flags << "#{label}_cell_differs" if value && (cell.to_f - value.to_f).abs > 0.02
          cell.to_f.round(2)
        else
          flags << "#{label}_not_in_cell"
          nil
        end
      end

      # ---- master option list -----------------------------------------------

      def master_list?(sheet)
        (sheet.first_row..[sheet.first_row + 4, sheet.last_row].min).any? do |r|
          sheet.row(r).compact.any? { |v| v.to_s.match?(/option\s*(no|#|number|code)/i) }
        end
      rescue StandardError
        false
      end

      def extract_master_list(name, sheet)
        header_row = (sheet.first_row..sheet.last_row).find { |r| sheet.row(r).compact.any? { |v| v.to_s.match?(/option\s*(no|#|number|code)/i) } }
        headers = sheet.row(header_row).map { |h| clean(h).to_s.downcase }
        code_i = headers.index { |h| h.match?(/option/) }
        desc_i = headers.index { |h| h.include?('description') }
        # Retail is the marked-up column ("PRICE"); cost is the factory figure.
        cost_i = headers.index { |h| h.match?(/factory|cost|dealer|net/) }
        retail_i = headers.index { |h| h.match?(/\A(price|retail|msrp)/) }
        markup = (header_row..[header_row + 3, sheet.last_row].min).filter_map do |r|
          row = sheet.row(r)
          i = row.index { |v| v.to_s.match?(/mark\s*up|\A%\z/i) }
          row[i + 1] if i && row[i + 1].is_a?(Numeric)
        end.first

        codes = Hash.new(0)
        count = 0
        ((header_row + 1)..sheet.last_row).each do |r|
          row = sheet.row(r)
          code = clean(row[code_i]).to_s
          next unless code.match?(/\A[A-Z]{1,4}\d{3,}/)

          codes[code] += 1
          count += 1
          cost = row[cost_i].is_a?(Numeric) ? row[cost_i].to_f.round(2) : nil
          retail = row[retail_i].is_a?(Numeric) ? row[retail_i].to_f.round(2) : nil
          flags, cost, retail = Checks.markup_check(cost, retail, markup)
          @sink.item(document: @doc, item_type: 'option', flags: flags,
                     source_ref: { 'document_id' => @doc.id, 'sheet' => name, 'row' => r },
                     payload: { 'kind' => 'coded', 'tab' => name, 'factory_code' => code,
                                'description' => clean(row[desc_i]).to_s, 'dealer_cost' => cost,
                                'suggested_retail' => retail, 'markup' => markup }.compact)
        end

        dupes = codes.select { |_, n| n > 1 }.keys
        if dupes.any?
          @sink.flag_items(@doc, ->(p) { dupes.include?(p['factory_code']) }, 'duplicate_factory_code')
        end
        { 'kind' => 'master_list', 'markup' => markup, 'codes' => count, 'duplicate_codes' => dupes }
      end

      # ---- announcements ----------------------------------------------------

      def extract_announcements(name, grid)
        input = @sink.claude(content: [{ type: 'text', text: grid.map(&:last).join("\n") }],
                             tool: Tools::PRODUCT_CHANGES,
                             system: 'Record each product change: what was discontinued, what replaces it, what is new, with dates.',
                             max_tokens: 8_000)[:input]
        changes = Array(input['changes'])
        changes.each do |c|
          @sink.item(document: @doc, item_type: 'product_change', flags: [],
                     source_ref: { 'document_id' => @doc.id, 'sheet' => name }, payload: c.to_h.deep_stringify_keys)
        end
        { 'kind' => 'announcements', 'changes' => changes.size }
      end

      # ---- sheet helpers ----------------------------------------------------

      def grid_rows(sheet)
        return [] if sheet.first_row.nil?

        (sheet.first_row..sheet.last_row).filter_map do |r|
          cells = (sheet.first_column..sheet.last_column).filter_map do |c|
            v = clean(sheet.cell(r, c))
            next if v.nil? || v == ''

            "#{col_letter(c)}#{r}=#{v.is_a?(String) ? v.inspect : v}"
          end
          [r, cells.join(' | ')] if cells.any?
        end
      end

      def price_cells(sheet)
        @price_cells ||= {}
        @price_cells[sheet.object_id] ||= begin
          refs = []
          if sheet.first_row
            (sheet.first_row..sheet.last_row).each do |r|
              (sheet.first_column..sheet.last_column).each do |c|
                v = sheet.cell(r, c)
                refs << "#{col_letter(c)}#{r}" if v.is_a?(Numeric) && PRICE_RANGE.cover?(v.abs)
              end
            end
          end
          refs
        end
      end

      def cell_value(sheet, ref)
        md = ref.to_s.upcase.match(/\A([A-Z]+)(\d+)\z/) or return nil
        col = md[1].chars.reduce(0) { |a, ch| a * 26 + ch.ord - 64 }
        sheet.cell(md[2].to_i, col)
      end

      def clean(v)
        case v
        when String then v.gsub(/<[^>]+>/, '').gsub(/\s+/, ' ').strip
        when Date, DateTime then v.to_s
        when Float then (v.round(4) == v.round ? v.round : v.round(4))
        else v
        end
      end

      def col_letter(n)
        s = +''
        while n.positive?
          n, r = (n - 1).divmod(26)
          s.prepend((65 + r).chr)
        end
        s
      end
    end
  end
end
