# frozen_string_literal: true

# A change order the buyers sign (Agreements::BuyerChangeOrder): what changes
# from the signed Deal Sheet, line by line and color by color, at retail, and
# the contract total before and after. Dealer-branded. Signed by the same
# people as the agreement; placements are their signature and date fields,
# by signing order.
class BuyerChangeOrderPdfGenerator
  CHANGE = { 'add' => 'Add', 'remove' => 'Remove', 'quantity' => 'Change quantity', 'price' => 'Price change' }.freeze
  TERMS = 'This change order amends the purchase agreement named above. Except as changed here, every term of that ' \
          'agreement stays in force. The prices above replace the ones in the agreement for the items listed. After the ' \
          'home is released to production, a change also needs the manufacturer to accept it, and may add cost and delay.'
  INK = AgreementSheetsPdfGenerator::INK
  MUTED = AgreementSheetsPdfGenerator::MUTED
  RULE = AgreementSheetsPdfGenerator::RULE
  HEAD = AgreementSheetsPdfGenerator::HEAD
  PAGE_W = AgreementSheetsPdfGenerator::PAGE_W
  PAGE_H = AgreementSheetsPdfGenerator::PAGE_H

  attr_reader :placements

  # signers: [{ label:, name: }] in signing order.
  def initialize(change_order, number:, agreement_number:, parent_number:, signers:)
    @co = change_order
    @build = change_order.draft
    @deal = @build.deal
    @number = number
    @agreement_number = agreement_number
    @parent_number = parent_number
    @signers = signers
    @placements = []
  end

  def generate
    pdf = AgreementSheetsPdfGenerator.document
    sheets = AgreementSheetsPdfGenerator.new(@build)
    letterhead(pdf, sheets)
    identification(pdf, sheets)
    changes = @co.changes
    lines(pdf, changes[:lines]) if changes[:lines].any?
    colors(pdf, changes[:colors]) if changes[:colors].any?
    totals(pdf, changes[:totals])
    pdf.text TERMS, size: 8.5, color: INK, leading: 1.5
    pdf.move_down 14
    signatures(pdf)
    footer(pdf)
    pdf.render
  end

  private

  def money(v) = Agreements::PacketValues.money(v) || 'Not priced'

  def letterhead(pdf, sheets)
    top = pdf.cursor
    half = pdf.bounds.width / 2
    pdf.bounding_box([0, top], width: half - 10) do
      pdf.text @deal.company.name.to_s, size: 13, style: :bold, color: INK
      sheets.dealer_address.each { |l| pdf.text l, size: 8, color: MUTED }
    end
    left = pdf.cursor
    pdf.bounding_box([half, top], width: half) do
      pdf.text "Change Order No. #{@number}", size: 13, style: :bold, color: INK, align: :right
      pdf.text "To purchase agreement #{@parent_number}  |  #{@agreement_number}", size: 8, color: MUTED, align: :right
      pdf.text Date.current.strftime('%b %-d, %Y'), size: 8, color: MUTED, align: :right
    end
    pdf.move_cursor_to [left, pdf.cursor].min - 8
    pdf.stroke_color RULE
    pdf.stroke_horizontal_rule
    pdf.move_down 10
  end

  def identification(pdf, sheets)
    buyers = [@deal.contact, @deal.co_applicant_contact].compact.map { |c| [c.first_name, c.last_name].compact.join(' ') }
    w = pdf.bounds.width
    rows = [["<b>BUYER</b>", buyers.join(' and '), '<b>DEAL</b>', @deal.deal_number.to_s],
            ["<b>HOME</b>", sheets_home(sheets), '<b>DEAL SHEET</b>', "#{@co.live.version_name} to #{@build.version_name}"]]
    pdf.table(rows, width: w, column_widths: [w * 0.12, w * 0.43, w * 0.15, w * 0.30],
                    cell_style: { size: 8.5, padding: [4, 5], border_color: RULE, text_color: INK, inline_format: true }) do |t|
      t.columns([0, 2]).background_color = HEAD
    end
    pdf.move_down 12
  end

  def sheets_home(_sheets) = Truebuild::FactoryOrder.home_name(@build)

  def lines(pdf, rows)
    table = [['Change', 'Item', 'Qty', 'Was', 'Now', 'Difference']]
    rows.each do |r|
      qty = r['change'] == 'quantity' ? "#{r['quantity_from']} to #{r['quantity_to']}" : (r['quantity_to'] || r['quantity_from']).to_s
      table << [CHANGE[r['change']], [r['description'], (r['code'] && "Code #{r['code']}")].compact.join("\n"), qty,
                r['price_from'].nil? ? '' : money(r['price_from']), r['price_to'].nil? ? '' : money(r['price_to']), money(r['delta'])]
    end
    w = pdf.bounds.width
    pdf.table(table, header: true, width: w, column_widths: [w * 0.14, w * 0.38, w * 0.1, w * 0.12, w * 0.12, w * 0.14],
                     cell_style: { size: 8.5, padding: [4, 5], border_color: RULE, text_color: INK }) do |t|
      t.row(0).font_style = :bold
      t.row(0).background_color = HEAD
      t.columns(3..5).align = :right
    end
    pdf.move_down 10
  end

  def colors(pdf, rows)
    pdf.text 'Colors and finishes', style: :bold, size: 10, color: INK
    pdf.move_down 4
    table = [%w[Selection Was Now]] + rows.map { |c| [c['set'], c['from'].presence || 'Not chosen', c['to']] }
    pdf.table(table, header: true, width: pdf.bounds.width, cell_style: { size: 8.5, padding: [4, 5], border_color: RULE, text_color: INK }) do |t|
      t.row(0).font_style = :bold
      t.row(0).background_color = HEAD
    end
    pdf.move_down 10
  end

  def totals(pdf, t)
    rows = [['Contract total before this change', money(t['contract_before'])],
            ['Contract total with this change', money(t['contract_after'])],
            ['Difference', money(t['difference'])]]
    rows << ['Unpaid balance with this change', money(t['unpaid_after'])] if t['unpaid_after']
    w = 300
    pdf.table(rows, position: :right, width: w, column_widths: [w * 0.64, w * 0.36],
                    cell_style: { size: 9, padding: [3, 5], border_width: 0, text_color: INK }) do |tb|
      tb.column(1).align = :right
      tb.row(2).font_style = :bold
      tb.row(2).borders = [:top]
      tb.row(2).border_width = 0.75
    end
    pdf.move_down 14
  end

  def signatures(pdf)
    pdf.start_new_page if pdf.cursor < (@signers.size.to_f / 2).ceil * 40 + 10
    col = pdf.bounds.width / 2
    @signers.each_slice(2).with_index do |pair, row|
      line_y = pdf.cursor - 22
      pair.each_with_index do |s, i|
        index = row * 2 + i
        x = i * col
        sig_w = col * 0.62
        date_x = x + col * 0.66
        date_w = col * 0.30
        pdf.stroke_color INK
        pdf.stroke_line [x, line_y], [x + sig_w, line_y]
        pdf.stroke_line [date_x, line_y], [date_x + date_w, line_y]
        place(pdf, index, 'signature', x, line_y + 20, sig_w, 20, "#{s[:label]} signature")
        place(pdf, index, 'date_signed', date_x, line_y + 14, date_w, 14, "#{s[:label]} date")
        pdf.draw_text "#{s[:label]}: #{s[:name]}", at: [x, line_y - 8], size: 6.5
        pdf.draw_text 'Date', at: [date_x, line_y - 8], size: 6.5
      end
      pdf.move_cursor_to line_y - 16
    end
  end

  def place(pdf, index, type, x, top, w, h, label)
    left = pdf.bounds.absolute_left + x
    abs_top = pdf.bounds.absolute_bottom + top
    @placements << { 'id' => "co_#{@placements.size + 1}", 'fieldKey' => "signer.#{type}", 'fieldLabel' => label, 'fieldType' => type,
                     'page' => pdf.page_number - 1, 'x' => (left / PAGE_W * 100).round(2), 'y' => ((PAGE_H - abs_top) / PAGE_H * 100).round(2),
                     'width' => (w / PAGE_W * 100).round(2), 'height' => (h / PAGE_H * 100).round(2),
                     'isSignerField' => true, 'isCustomField' => false, 'signerIndex' => index }
  end

  def footer(pdf)
    total = pdf.page_count
    (1..total).each do |n|
      pdf.go_to_page(n)
      pdf.canvas do
        pdf.draw_text "Change Order No. #{@number}  |  #{@agreement_number}  |  Deal #{@deal.deal_number}  |  Page #{n} of #{total}",
                      at: [AgreementSheetsPdfGenerator::MARGIN, 16], size: 6.5
      end
    end
  end
end
