# frozen_string_literal: true

module Agreements
  # Renders a dealer's agreement package (AgreementTemplate#packet) for one
  # deal: their contract, in their wording, filled from the deal (PacketValues),
  # with the standard sheets (Schedule A, Colors) drawn in place of the
  # contract's own option and color pages. One PDF, ready to sign.
  #
  # The contract is a document model: sheets of blocks (letterhead, table,
  # paragraph, body, bullet, init, ack, sig, page break) whose text runs carry
  # blanks: tx (text) and dd (a choice list), each with a tag, plus blanks
  # written as underscores. Every blank is one of:
  #   filled     a fill names a value we hold, drawn into the page;
  #   the rep's  no value: a field the rep fills in the builder before sending
  #              (a choice list keeps its choices);
  #   a signer's an initials ("x____"), signature ("X ____", "signature ____")
  #              or date spot, signed in the signing pass.
  # Every spot is measured where it is drawn, so nothing is placed by hand.
  #
  # packet = {
  #   'doc'     => { sheet => [blocks] },
  #   'order'   => [sheet keys, in packet order],
  #   'standard_sheets' => { 'addA' => 'schedule_a', 'color' => 'colors' },
  #   'titles'  => { 'schedule_a' => 'Addendum "A": ...' },
  #   'signers' => %w[buyer_1 rep manager buyer_2],   signing order
  #   'fills'   => { 'page1.f21' => 'buyer_1.name', 'docs.DocSt1' => '=In file' },  '=' a literal
  #   'rows'    => { 'page1' => { '1' => 'price.base', 'GROSS SELLING PRICE' => 'price.gross' } },
  #   'inline'  => { 'page1' => [[row_key_or_nil, 'CONTINGENCY DEADLINE', 'sale.contingency_deadline']] }
  # }
  class PacketRenderer
    Result = Struct.new(:pdf, :placements, :definitions, :signers, :page_count, keyword_init: true)

    PAGE_W = AgreementSheetsPdfGenerator::PAGE_W
    PAGE_H = AgreementSheetsPdfGenerator::PAGE_H
    INK = '111827'
    MUTED = '6B7280'
    RULE = '9CA3AF'
    FILL = '1E3A8A' # filled-in values, so a reader sees what was typed for this deal
    TOTAL_TWIPS = 10_800.0
    PLACEHOLDER = /\A(\u2014|-+)?\s*(select)?\s*(\u2014|-+)?\z/i
    SIGNER_LABELS = { 'buyer_1' => 'Buyer 1', 'buyer_2' => 'Buyer 2', 'rep' => 'Dealer Representative', 'manager' => 'Manager / Member' }.freeze
    FIELD_TYPES = { 'signature' => 'signature', 'initials' => 'initials', 'date' => 'date_signed' }.freeze

    # A blank inside a run of text: where it is drawn is recorded when Prawn draws it.
    class Spot
      attr_reader :box

      def render_behind(fragment)
        @box ||= fragment.absolute_bounding_box
      end
    end

    def initialize(deal, template, agreement_number: nil, date: Date.current)
      @deal = deal
      @template = template
      @packet = template.packet.to_h
      @values = PacketValues.new(deal, agreement_number: agreement_number, date: date)
      @fills = @packet['fills'].to_h
      @spots = []       # [{ page, signer, kind, box }]
      @fields = {}      # key => definition
      @field_spots = [] # [{ page, key, box }]
      present = %w[buyer_1 buyer_2].select { |b| @values["#{b}.name"] }
      @signers = Array(@packet['signers']).presence || %w[buyer_1 rep manager buyer_2]
      @signers = @signers.reject { |s| s.start_with?('buyer') && !present.include?(s) }
    end

    def call
      pdf = AgreementSheetsPdfGenerator.document
      sheets = @deal.home_build && AgreementSheetsPdfGenerator.new(@deal.home_build, titles: @packet['titles'].to_h)
      sheet_ranges = {}
      Array(@packet['order']).each_with_index do |key, i|
        new_page(pdf) if i.positive?
        @sheet = key
        @sheet_title = nil
        @headers = nil
        standard = @packet['standard_sheets'].to_h[key]
        if standard
          next sheet_ranges[standard] = sheets.render_sheet(pdf, standard) if sheets

          pdf.text 'This page fills from the Deal Sheet once the deal has one.', color: MUTED
        else
          Array(@packet.dig('doc', key)).each { |block| draw_block(pdf, block) }
        end
      end
      sheets&.footers(pdf, sheet_ranges)
      page_numbers(pdf)
      Result.new(pdf: pdf.render, placements: placements(sheets), definitions: @fields.values,
                 signers: @signers, page_count: pdf.page_count)
    end

    private

    # ── Blocks ────────────────────────────────────────────────────────────

    def draw_block(pdf, block)
      @row_key = nil
      @row_text = +''
      @inline_used = []
      case block['t']
      when 'letterhead' then letterhead(pdf, block)
      when 'table' then table(pdf, block)
      when 'p' then paragraph(pdf, block['runs'], pdf.bounds.width, align: block['align'])
      when 'body' then paragraph(pdf, [{ 't' => 'run', 'text' => block['text'] }], pdf.bounds.width)
      when 'bullet' then bullet(pdf, block['text'])
      when 'init' then initialed(pdf, block['text'])
      when 'ack' then paragraph(pdf, [{ 't' => 'run', 'text' => block['text'], 'bold' => true }], pdf.bounds.width)
      when 'sig' then signature_block(pdf, block['full'])
      when 'sp' then pdf.move_down 6
      when 'brk' then new_page(pdf)
      end
    end

    # A page break, unless the page is still empty (a sheet ends with one,
    # and the next sheet starts on a new page anyway).
    def new_page(pdf)
      pdf.start_new_page if pdf.cursor < pdf.bounds.top - 1
    end

    def letterhead(pdf, block)
      @sheet_title ||= block['title'].to_s.split(/\s+[\u2014-]\s+/).first.presence
      top = pdf.cursor
      half = pdf.bounds.width * 0.42
      pdf.bounding_box([0, top], width: half) do
        pdf.text clean(@deal.company.name), size: 11, style: :bold, color: INK
        dealer_address.each { |l| pdf.text clean(l), size: 7, color: MUTED }
      end
      left = pdf.cursor
      pdf.bounding_box([half, top], width: pdf.bounds.width - half) do
        pdf.text clean(block['title']), size: 12, style: :bold, color: INK, align: :right
        pdf.text clean(block['sub']), size: 7, color: MUTED, align: :right if block['sub'].present?
      end
      pdf.move_cursor_to [left, pdf.cursor].min - 5
      pdf.stroke_color RULE
      pdf.stroke_horizontal_rule
      pdf.move_down 6
    end

    def dealer_address
      @dealer_address ||= @values.build ? AgreementSheetsPdfGenerator.new(@values.build).dealer_address : []
    end

    def bullet(pdf, text)
      indent = 10
      pdf.draw_text "\u2022", at: [2, pdf.cursor - 7], size: 7.5
      pdf.indent(indent) { paragraph(pdf, [{ 't' => 'run', 'text' => text }], pdf.bounds.width) }
    end

    # A statement the buyers initial: their two boxes, then the text.
    def initialed(pdf, text)
      box_w = 30
      gutter = 2 * box_w + 14
      need = pdf.height_of(clean(text), width: pdf.bounds.width - gutter, size: size_for(nil)) + 6
      pdf.start_new_page if pdf.cursor < need
      top = pdf.cursor
      buyers.each_with_index do |b, i|
        x = i * (box_w + 6)
        pdf.stroke_color RULE
        pdf.stroke_rectangle [x, top - 1], box_w, 12
        mark(pdf, b, 'initials', x, top - 1, box_w, 12)
      end
      frags = fragments([{ 't' => 'run', 'text' => text }])
      h = pdf.height_of_formatted(frags, width: pdf.bounds.width - gutter)
      pdf.formatted_text_box(frags, at: [gutter, top], width: pdf.bounds.width - gutter, height: h + 2, leading: 0.6)
      record_spots(pdf)
      pdf.move_cursor_to top - [h, 13].max - 3
    end

    # Signature and date lines: the buyers, and on a full block the dealer's
    # representative and a manager too, two to a row.
    def signature_block(pdf, full)
      who = buyers + (full ? (@signers & %w[rep manager]) : [])
      rows = who.each_slice(2).to_a
      pdf.start_new_page if pdf.cursor < rows.size * 34 + 8
      pdf.move_down 6
      col = pdf.bounds.width / 2
      rows.each do |pair|
        line_y = pdf.cursor - 20
        pair.each_with_index do |s, i|
          x = i * col
          sig_w = col * 0.62
          date_x = x + col * 0.66
          date_w = col * 0.30
          pdf.stroke_color INK
          pdf.stroke_line [x, line_y], [x + sig_w, line_y]
          pdf.stroke_line [date_x, line_y], [date_x + date_w, line_y]
          mark(pdf, s, 'signature', x, line_y + 18, sig_w, 18)
          mark(pdf, s, 'date', date_x, line_y + 14, date_w, 14)
          pdf.draw_text "#{SIGNER_LABELS[s]} signature", at: [x, line_y - 8], size: 6.5
          pdf.draw_text 'Date', at: [date_x, line_y - 8], size: 6.5
        end
        pdf.move_cursor_to line_y - 14
      end
    end

    # ── Tables ────────────────────────────────────────────────────────────

    def table(pdf, block)
      Array(block['rows']).each { |row| table_row(pdf, row) }
      pdf.move_down 2
    end

    def table_row(pdf, row)
      cells = Array(row['cells'])
      return if cells.empty?

      width = pdf.bounds.width
      total = cells.sum { |c| c['w'].to_f.positive? ? c['w'].to_f : TOTAL_TWIPS / cells.size }
      widths = cells.map { |c| (c['w'].to_f.positive? ? c['w'].to_f : TOTAL_TWIPS / cells.size) / total * width }
      @row_key = cells.map { |c| plain(c['content']).strip }.find(&:present?).to_s
      @row_text = +''
      @inline_used = []
      contents = cells.map { |c| cell_content(c) }
      header = contents.none? { |c| c[:field] || c[:price] } && contents.count { |c| c[:paras] }.positive?
      heights = contents.each_with_index.map { |content, i| content_height(pdf, content, widths[i] - 6) + 4 }
      height = [heights.max, 11].max
      pdf.start_new_page if pdf.cursor < height
      top = pdf.cursor
      x = 0
      cells.each_with_index do |c, i|
        w = widths[i]
        if c['shade'].present?
          pdf.fill_color c['shade'].to_s.delete('#')
          pdf.fill_rectangle [x, top], w, height
          pdf.fill_color '000000'
        end
        pdf.stroke_color RULE
        pdf.line_width 0.4
        pdf.stroke_rectangle [x, top], w, height
        pdf.line_width 1
        @row_text << ' | '
        @last_cell = i == cells.size - 1
        @col = i
        @col_count = cells.size
        draw_cell(pdf, contents[i], c, x, top, w, height)
        x += w
      end
      pdf.move_cursor_to top - height
      @headers = cells.map { |c| plain(c['content']).strip } if header
    end

    # A cell's paragraphs as lists of runs; a cell whose only content is one
    # blank becomes that blank, drawn over the whole cell.
    def cell_content(cell)
      paras = Array(cell['content']).select { |p| p['t'] == 'p' }
      runs = paras.flat_map { |p| Array(p['runs']) }
      only = runs.reject { |r| r['t'] == 'run' && r['text'].to_s.strip.empty? }
      return { field: only.first, cell: cell } if only.size == 1 && %w[tx dd].include?(only.first['t'])

      text = plain(cell['content']).strip
      return { empty: true, cell: cell } if text.empty? && only.empty?
      return { price: true, negative: text.start_with?('('), cell: cell } if text.match?(/\A\(?\s*\$\s*\)?\z/)

      { paras: paras, cell: cell }
    end

    def draw_cell(pdf, content, cell, x, top, w, h)
      return blank_cell(pdf, content[:field], cell, x, top, w, h) if content[:field]
      return price_cell(pdf, content, cell, x, top, w, h) if content[:price]
      return (empty_cell(pdf, cell, x, top, w, h) if @last_cell) if content[:empty]

      y = top - 2.5
      content[:paras].each do |p|
        frags = fragments(p['runs'], size: cell['size'], bold: cell['bold'])
        next if frags.empty?

        ph = pdf.height_of_formatted(frags, width: w - 6)
        pdf.formatted_text_box(frags, at: [x + 3, y], width: w - 6, height: ph + 2, overflow: :shrink_to_fit,
                                      align: (p['align'] || cell['align']).presence&.to_sym || :left, leading: 0.6)
        record_spots(pdf)
        y -= ph + 1
      end
    end

    # A "$" cell of a price ladder: the row's figure, a deduction in
    # parentheses; a row with no figure is the rep's to fill.
    def price_cell(pdf, content, cell, x, top, w, h)
      key = row_rule
      value = key && @values[key]
      if value
        text = content[:negative] ? "(#{value})" : value
        pdf.text_box clean(text), at: [x + 3, top - 2.5], width: w - 8, height: h - 3, align: :right, overflow: :shrink_to_fit,
                                  size: size_for(cell['size']), color: FILL, style: :bold
        @row_text << " #{text}"
      else
        node = { 't' => 'tx', 'tag' => "amount_#{@row_key.parameterize(separator: '_').first(40)}", 'label' => @row_key.truncate(60) }
        field(node, [pdf.bounds.absolute_left + x + 2, pdf.bounds.absolute_bottom + top - h + 1,
                     pdf.bounds.absolute_left + x + w - 2, pdf.bounds.absolute_bottom + top - 1], pdf.page_number)
      end
    end

    # The row's value from the packet's rows (a contingency description in
    # the empty cell beside its label); nothing when it has none.
    def empty_cell(pdf, cell, x, top, w, h)
      key = row_rule
      value = key && @values[key]
      return unless value

      pdf.text_box clean(value), at: [x + 3, top - 2.5], width: w - 6, height: h - 3, overflow: :shrink_to_fit,
                                 size: size_for(cell['size']), color: FILL, style: :bold
      @row_text << " #{value}"
    end

    # The rows rule for this row: the longest label it starts with. A key of
    # one or two characters (a line number: "1", "A", "10") must match exactly.
    def row_rule
      rules = @packet.dig('rows', @sheet).to_h.select { |k, _| k.length <= 2 ? @row_key == k : @row_key.start_with?(k) }
      rules.max_by { |k, _| k.length }&.last
    end

    # A whole-cell blank: the value, or a field for the rep over the cell.
    def blank_cell(pdf, node, cell, x, top, w, h)
      value = value_for(node)
      if value
        pdf.text_box clean(value), at: [x + 3, top - 2.5], width: w - 6, height: h - 3, overflow: :shrink_to_fit,
                                   size: size_for(cell['size']), color: FILL, style: :bold
        @row_text << " #{value}"
      else
        field(node, [pdf.bounds.absolute_left + x + 2, pdf.bounds.absolute_bottom + top - h + 1,
                     pdf.bounds.absolute_left + x + w - 2, pdf.bounds.absolute_bottom + top - 1], pdf.page_number)
      end
    end

    def content_height(pdf, content, width)
      return size_for(content[:cell]['size']) + 4 if content[:field] || content[:price] || content[:empty]

      content[:paras].sum do |p|
        frags = fragments(p['runs'], size: content[:cell]['size'], bold: content[:cell]['bold'], measure: true)
        frags.empty? ? 0 : pdf.height_of_formatted(frags, width: width) + 1
      end
    end

    # ── Paragraphs and blanks ─────────────────────────────────────────────

    def paragraph(pdf, runs, width, align: nil, size: nil, bold: nil)
      frags = fragments(runs, size: size, bold: bold)
      return if frags.empty?

      need = pdf.height_of_formatted(frags, width: width)
      pdf.start_new_page if pdf.cursor < [need, 120].min
      pdf.formatted_text(frags, width: width, align: (align.presence || 'left').to_sym, leading: 0.6)
      record_spots(pdf)
      pdf.move_down 3
    end

    # Runs to Prawn fragments. Blanks get a Spot callback; measure: true builds
    # the same fragments without recording anything.
    def fragments(runs, size: nil, bold: nil, measure: false)
      @pending = [] unless measure
      out = []
      Array(runs).each do |r|
        base = { size: size_for(r['size'] || size), color: (r['color'].presence || INK).to_s.delete('#'), styles: [] }
        base[:styles] << :bold if r['bold'] || bold
        base[:styles] << :italic if r['italics']
        case r['t']
        when 'run' then text_fragments(r['text'].to_s, base, measure, out)
        when 'tx', 'dd'
          value = value_for(r)
          if value
            out << base.merge(text: clean(value), color: FILL, styles: base[:styles] | [:bold])
            @row_text << " #{value}" unless measure
          else
            out << blank_fragment(base, r, measure, r['t'] == 'dd' ? 18 : 22)
          end
        end
      end
      out
    end

    UNDERSCORES = /([xX] ?_{3,}|_{3,})/

    def text_fragments(text, base, measure, out)
      text = clean(text)
      text.split(UNDERSCORES).each do |part|
        next if part.empty?

        unless part.match?(/\A#{UNDERSCORES}\z/)
          out << base.merge(text: part)
          @row_text << part unless measure
          next
        end
        out.concat(underscore_fragments(part, base, measure))
      end
    end

    # x____ initials, X ____ a signature, "signature ____" too, "Date ____" a
    # date; a blank a fill names takes its value; any other is the rep's.
    def underscore_fragments(part, base, measure)
      context = @row_text.to_s
      lead = part[/\A[xX] ?/].to_s
      inline = inline_value(context) if lead.empty?
      if inline
        @row_text << " #{inline}" unless measure
        return [base.merge(text: " #{inline} ", color: FILL, styles: base[:styles] | [:bold])]
      end

      kind = if lead.start_with?('x') then 'initials'
             elsif lead.start_with?('X') || context.match?(/signature\s*\z/i) then 'signature'
             elsif context.match?(/date\s*\z/i) then 'date'
             end
      out = []
      out << base.merge(text: lead) if lead.present?
      line = base.merge(text: "\u00a0" * [part.length - lead.length, 6].max, styles: base[:styles] | [:underline], color: RULE)
      unless measure
        spot = Spot.new
        line[:callback] = spot
        @pending << (kind ? { kind: kind, spot: spot } : { field: { 't' => 'tx', 'tag' => blank_tag(context), 'label' => label_from(context) }, spot: spot })
        @row_text << ' '
      end
      out << line
    end

    def blank_fragment(base, node, measure, width)
      frag = base.merge(text: "\u00a0" * width, styles: base[:styles] | [:underline], color: RULE)
      unless measure
        spot = Spot.new
        @pending << { field: node, spot: spot }
        frag[:callback] = spot
      end
      frag
    end

    # After a paragraph is drawn, its blanks know where they are.
    def record_spots(pdf)
      return @pending = [] if buyers.empty? && Array(@pending).none? { |p| p[:field] }

      who = { 'initials' => buyers.cycle, 'signature' => buyers.cycle }
      last = buyers.first
      Array(@pending).each do |p|
        box = p[:spot].box
        next unless box

        if p[:kind]
          next if buyers.empty?

          signer = p[:kind] == 'date' ? last : who[p[:kind]].next
          last = signer
          @spots << { page: pdf.page_number, signer: signer, kind: p[:kind], box: box } if signer
        else
          field(p[:field], box, pdf.page_number)
        end
      end
      @pending = []
    end

    # ── Values and the rep's fields ──────────────────────────────────────

    def value_for(node)
      key = @fills["#{@sheet}.#{node['tag']}"]
      raw = key.to_s.start_with?('=') ? key.to_s.delete_prefix('=') : (key && @values[key])
      return nil if raw.blank?
      return raw.to_s unless node['t'] == 'dd'

      choose(raw.to_s, node['items'])
    end

    # The choice our value names ("Topeka" picks "Topeka, IN"), else the value.
    def choose(value, items)
      items = Array(items).reject { |i| i.to_s.match?(PLACEHOLDER) }
      down = value.downcase
      items.find { |i| i.casecmp?(value) } || items.find { |i| i.downcase.start_with?(down) } ||
        items.find { |i| down.start_with?(i.downcase.split(/\s+/).first.to_s) && i.downcase.split(/\s+/).first.to_s.length > 2 } || value
    end

    def inline_value(context)
      rules = Array(@packet.dig('inline', @sheet))
      rules = rules.select { |row, label, _| (row.nil? || @row_key == row) && context.include?(label) && !@inline_used.include?(label) }
      return nil if rules.empty?

      rule = rules.max_by { |_, label, _| context.rindex(label) }
      @inline_used << rule[1]
      @values[rule.last].presence
    end

    def field(node, box, page = nil)
      tag = node['tag'].to_s
      key = "#{@sheet}_#{tag}".downcase.gsub(/[^a-z0-9_]/, '_')
      @fields[key] ||= begin
        items = Array(node['items']).reject { |i| i.to_s.match?(PLACEHOLDER) }
        d = { 'key' => key, 'label' => tidy(node['label']).presence || field_label, 'type' => 'text', 'group' => @sheet_title || @sheet,
              'required' => false, 'position' => @fields.size + 1, 'filled_by' => 'preparer' }
        d['options'] = items if items.any?
        d
      end
      @field_spots << { page: page, key: key, box: box }
    end

    # What the rep sees: the label beside the blank, and in a grid the
    # column's heading too ("Site work / excavation: CONTRACTOR NAME").
    def field_label
      label = tidy(@row_text.to_s.split('|').map(&:strip).reject(&:blank?).last.to_s)
      label = label.split(/(?<=[.:])\s/).last.to_s if label.length > 60
      column = @headers[@col].to_s.strip if @headers && @col && @headers.size == @col_count
      column = nil if column.blank? || label.include?(column)
      [label.presence, tidy(column).presence].compact.join(': ').truncate(80).presence || 'Blank'
    end

    def label_from(context) = tidy(context.to_s.split('|').map(&:strip).reject(&:blank?).last.to_s.split(/\s{2,}/).last.to_s).truncate(60)

    def tidy(text) = text.to_s.gsub(/_{2,}/, ' ').gsub(/\s+/, ' ').strip.sub(/[\s:]+\z/, '')

    def blank_tag(context)
      @blank_count = @blank_count.to_i + 1
      "line_#{@blank_count}_#{label_from(context).parameterize(separator: '_').first(30)}"
    end

    # ── Placements ───────────────────────────────────────────────────────

    def buyers = @signers.select { |s| s.start_with?('buyer') }.sort

    def mark(pdf, signer, kind, x, top, w, h)
      return unless @signers.include?(signer)

      left = pdf.bounds.absolute_left + x
      t = pdf.bounds.absolute_bottom + top
      @spots << { page: pdf.page_number, signer: signer, kind: kind, box: [left, t - h, left + w, t] }
    end

    def placements(sheets)
      index = @signers.each_with_index.to_h
      out = []
      @spots.each do |s|
        out << placement(s[:page], s[:box], "signer.#{FIELD_TYPES[s[:kind]]}", "#{SIGNER_LABELS[s[:signer]]} #{s[:kind].tr('_', ' ')}",
                         FIELD_TYPES[s[:kind]], 'isSignerField' => true, 'isCustomField' => false, 'signerIndex' => index[s[:signer]])
      end
      Array(sheets&.spots).each do |s|
        next unless index.key?(s['signer'])

        out << { 'id' => "packet_#{out.size + 1}", 'fieldKey' => "signer.#{FIELD_TYPES[s['kind']]}",
                 'fieldLabel' => "#{SIGNER_LABELS[s['signer']]} #{s['kind']}", 'fieldType' => FIELD_TYPES[s['kind']],
                 'page' => s['page'], 'x' => s['x'], 'y' => s['y'], 'width' => s['width'], 'height' => s['height'],
                 'isSignerField' => true, 'isCustomField' => false, 'signerIndex' => index[s['signer']] }
      end
      @field_spots.each do |f|
        d = @fields[f[:key]]
        out << placement(f[:page], f[:box], "custom.#{f[:key]}", d['label'], 'text', 'isSignerField' => false, 'isCustomField' => true)
      end
      out.each_with_index { |p, i| p['id'] = "packet_#{i + 1}" }
    end

    def placement(page, box, key, label, type, extra)
      left, bottom, right, top = box
      { 'id' => nil, 'fieldKey' => key, 'fieldLabel' => label, 'fieldType' => type, 'page' => page - 1,
        'x' => (left / PAGE_W * 100).round(2), 'y' => ((PAGE_H - top) / PAGE_H * 100).round(2),
        'width' => ((right - left) / PAGE_W * 100).round(2), 'height' => ([top - bottom, 9].max / PAGE_H * 100).round(2) }.merge(extra)
    end

    def page_numbers(pdf)
      total = pdf.page_count
      label = clean("#{@template.name}  |  Agreement #{@values['agreement.number']}")
      (1..total).each do |n|
        pdf.go_to_page(n)
        pdf.canvas { pdf.draw_text "#{label}  |  Page #{n} of #{total}", at: [AgreementSheetsPdfGenerator::MARGIN, 16], size: 6.5 }
      end
    end

    # ── Text ──────────────────────────────────────────────────────────────

    # The document model's sizes are half-points, as in a word processor.
    def size_for(size) = size.to_f.positive? ? [[size.to_f * 0.5, 6].max, 11].min : 7

    def plain(content)
      case content
      when Array then content.map { |c| plain(c) }.join
      when Hash then content['t'] == 'run' ? content['text'].to_s : plain(content['content'] || content['runs'])
      else ''
      end
    end

    # Characters the PDF's built-in fonts cannot draw.
    def clean(text) = text.to_s.gsub("\u2610", '[  ]').gsub("\u2611", '[X]').gsub(/[^\u0000-\u00ff\u2013\u2014\u2018\u2019\u201c\u201d\u2022\u2026\u20ac]/, '')
  end
end
