# frozen_string_literal: true

# The agreement's standard sheets as a PDF, from one Deal Sheet version
# (Truebuild::AgreementSheets): Schedule A, every option on the home with its
# price, and the Color and Finish Selections that go to the manufacturer. As
# many rows as the home has, never a fixed grid. Dealer-branded: the
# dealership's name and address, not the platform's.
#
# Each sheet ends with the buyers' and the dealer's signatures and carries
# the buyers' initials on every page. Where those go is kept in spots (page,
# signer, kind, and x/y/width/height as percentages of the page from the top
# left, as agreement field placements are measured) so the agreement packet
# can place its signing fields on them.
class AgreementSheetsPdfGenerator
  SHEETS = {
    'schedule_a' => { title: 'Schedule A: Options and Upgrades',
                      sub: 'Every option that is part of this home is listed on this schedule. Nothing verbal is included.' },
    'colors' => { title: 'Color and Finish Selections',
                   sub: 'This sheet goes to the manufacturer with the order. Colors shown in samples and photographs are representative only.' }
  }.freeze

  ACKNOWLEDGE = {
    'schedule_a' => 'Buyer has reviewed every option above. An option not listed on this schedule is not part of this home. ' \
                    'After the home is released to production, options change only by a signed change order the manufacturer ' \
                    'accepts, which may add cost and delay.',
    'colors' => 'Buyer has reviewed every selection above. Color and finish selections cannot be changed after the home is ' \
                'released to production except by a signed change order the manufacturer accepts, which may add cost and delay. ' \
                'Product samples, brochures and online renderings are representative only; actual materials may vary in color, ' \
                'grain and texture.'
  }.freeze

  PAGE_W = 612.0
  PAGE_H = 792.0
  MARGIN = 40
  FOOTER = 34 # the band at the bottom of every page: page number and initials
  INK = '1F2937'
  MUTED = '6B7280'
  RULE = 'D1D5DB'
  HEAD = 'F3F4F6'

  attr_reader :spots

  # titles: a dealer's own names for the sheets ({ 'schedule_a' => 'Addendum "A"' }).
  def initialize(build, sheets: SHEETS.keys, titles: {})
    @build = build
    @deal = build.deal
    @company = build.company
    @data = Truebuild::AgreementSheets.new(build)
    @sheets = sheets.map(&:to_s) & SHEETS.keys
    @titles = titles.to_h.transform_keys(&:to_s)
    @filled = DealSaleDetails.new(@deal).filled
    @spots = []
  end

  def generate
    pdf = self.class.document
    ranges = {}
    @sheets.each_with_index do |sheet, i|
      pdf.start_new_page if i.positive?
      ranges[sheet] = render_sheet(pdf, sheet)
    end
    footers(pdf, ranges)
    pdf.render
  end

  # The page setup every sheet is drawn for; an agreement packet uses it too.
  def self.document
    Prawn::Document.new(page_size: 'LETTER', margin: [MARGIN, MARGIN, MARGIN + FOOTER, MARGIN]).tap { |pdf| pdf.font_size 9 }
  end

  # Draws one sheet from the current page on; the pages it took.
  def render_sheet(pdf, sheet)
    first = pdf.page_number
    letterhead(pdf, sheet)
    home_identification(pdf)
    sheet == 'schedule_a' ? schedule(pdf) : colors(pdf)
    acknowledgment(pdf, sheet)
    signatures(pdf, sheet)
    (first..pdf.page_number)
  end

  def signers
    list = [{ key: 'buyer_1', label: 'Buyer', name: @filled[:buyer_1]&.dig(:name) }]
    list << { key: 'buyer_2', label: 'Co-Buyer', name: @filled[:buyer_2][:name] } if @filled[:buyer_2]
    list << { key: 'rep', label: 'Dealer representative', name: @deal.owner&.full_name }
    list
  end

  # Page numbers per sheet, and the buyers' initials on every page.
  def footers(pdf, ranges)
    buyers = signers.select { |s| s[:key].start_with?('buyer') }
    ranges.each do |sheet, pages|
      pages.each_with_index do |page, i|
        pdf.go_to_page(page)
        pdf.canvas do
          y = MARGIN + 14
          pdf.fill_color MUTED
          pdf.draw_text "#{title(sheet)}  |  Page #{i + 1} of #{pages.size}  |  Deal #{@deal.deal_number}", at: [MARGIN, y - 10], size: 7
          x = PAGE_W - MARGIN
          buyers.reverse_each do |b|
            x -= 54
            pdf.stroke_color INK
            pdf.stroke_line [x, y - 12], [x + 46, y - 12]
            pdf.draw_text "#{b[:label]} initials", at: [x, y - 20], size: 6
            @spots << placement(page, sheet, b[:key], 'initials', x, y + 2, 46, 14)
          end
          pdf.fill_color '000000'
        end
      end
    end
  end

  # The dealership's address lines: the deal's location, else the first active one.
  def dealer_address
    loc = @build.location || @deal.location || @company.locations.where(active: true).first
    return [] unless loc

    street = loc.try(:address_line1).presence || loc.try(:address).presence
    city = [loc.try(:city), [loc.try(:state), loc.try(:zip_code).presence || loc.try(:zip)].compact.join(' ')].reject(&:blank?).join(', ')
    [street, city.presence, loc.try(:phone).presence].compact
  end

  private

  def title(sheet) = @titles[sheet].presence || SHEETS[sheet][:title]

  def letterhead(pdf, sheet)
    top = pdf.cursor
    half = pdf.bounds.width / 2
    pdf.bounding_box([0, top], width: half - 10) do
      pdf.text @company.name.to_s, size: 13, style: :bold, color: INK
      dealer_address.each { |l| pdf.text l, size: 8, color: MUTED }
    end
    left_bottom = pdf.cursor
    pdf.bounding_box([half, top], width: half) do
      pdf.text title(sheet), size: 13, style: :bold, color: INK, align: :right
      pdf.text SHEETS[sheet][:sub], size: 8, color: MUTED, align: :right
    end
    pdf.move_cursor_to [left_bottom, pdf.cursor].min - 8
    pdf.stroke_color RULE
    pdf.stroke_horizontal_rule
    pdf.move_down 10
  end

  def home_identification(pdf)
    buyers = [@filled[:buyer_1], @filled[:buyer_2]].compact.map { |b| b[:name] }.reject(&:blank?)
    serial = @filled[:serial_number].presence || 'Assigned when the home is built'
    sheet_date = (@build.priced_at || @build.updated_at)&.strftime('%b %-d, %Y')
    rows = [
      [label('BUYER'), buyers.join(' and ').presence || 'Not entered', label('DEAL'), @deal.deal_number.to_s],
      [label('HOME'), @data.home_name, label('SIZE'), @data.home_size],
      [label('SERIAL / MID'), serial, label('DEAL SHEET'), ["Version #{@build.version_number}", sheet_date].compact.join(', ')]
    ]
    w = pdf.bounds.width
    pdf.table(rows, width: w, column_widths: [w * 0.13, w * 0.42, w * 0.13, w * 0.32],
                    cell_style: { size: 9, padding: [4, 5], border_color: RULE, text_color: INK, inline_format: true }) do |t|
      t.columns([0, 2]).background_color = HEAD
    end
    pdf.move_down 12
  end

  def label(text) = "<font size='7'><b>#{text}</b></font>"

  def schedule(pdf)
    rows = @data.schedule_rows
    if rows.empty?
      pdf.text 'No options: the home as the manufacturer builds it standard.', color: MUTED
      pdf.move_down 10
    else
      table = [['#', 'Option or upgrade', 'Category', 'Status', 'Qty', 'Price']]
      rows.each_with_index do |r, i|
        detail = [escape(r['description'])]
        detail << "<font size='7.5'><color rgb='#{MUTED}'>Code #{escape(r['code'])}</color></font>" if r['code']
        detail << "<font size='7.5'><color rgb='#{MUTED}'>Includes: #{escape(r['includes'].join('; '))}</color></font>" if r['includes'].any?
        table << [(i + 1).to_s, detail.join("\n"), r['group'].to_s, r['status'], quantity(r), price(r)]
      end
      w = pdf.bounds.width
      pdf.table(table, header: true, width: w, column_widths: [w * 0.05, w * 0.45, w * 0.15, w * 0.12, w * 0.09, w * 0.14],
                       cell_style: { size: 8.5, padding: [4, 5], border_color: RULE, text_color: INK, inline_format: true }) do |t|
        t.row(0).font_style = :bold
        t.row(0).background_color = HEAD
        t.columns(4..5).align = :right
      end
      pdf.move_down 8
    end
    summary(pdf)
  end

  def summary(pdf)
    base = @data.base_price
    total = @data.options_total
    rows = [['Base home', money(base)], ['Options and upgrades on this schedule', money(total)]]
    rows << ['Home with options', money(base && base + total)]
    w = 290
    pdf.table(rows, position: :right, width: w, column_widths: [w * 0.62, w * 0.38],
                    cell_style: { size: 9, padding: [3, 5], border_width: 0, text_color: INK }) do |t|
      t.column(1).align = :right
      t.row(-1).font_style = :bold
      t.row(-1).borders = [:top]
      t.row(-1).border_width = 0.75
      t.row(-1).border_color = INK
    end
    pdf.move_down 6
    pdf.text 'Freight, set-up, fees, discounts and tax are on the agreement, not this schedule.', size: 7.5, color: MUTED, align: :right
    pdf.move_down 12
  end

  def colors(pdf)
    rows = @data.color_rows
    if rows.empty?
      pdf.text 'This model has no color or finish choices in the current price book.', color: MUTED
      pdf.move_down 10
      return
    end

    w = pdf.bounds.width
    rows.group_by { |c| c['group'] }.each do |group, sets|
      table = [[{ content: group.upcase, colspan: 3, font_style: :bold, background_color: HEAD, size: 8 }]]
      sets.each do |c|
        choice = c['choice'].presence || (c['skipped'] ? 'Not on this home' : 'Not chosen yet')
        table << [c['set'].to_s, choice, c['code'] ? "Code #{c['code']}" : '']
      end
      pdf.table(table, width: w, column_widths: [w * 0.34, w * 0.48, w * 0.18],
                       cell_style: { size: 9, padding: [4, 5], border_color: RULE, text_color: INK }) do |t|
        t.column(2).text_color = MUTED
        (1...table.size).each { |i| t.row(i).column(1).font_style = :bold if sets[i - 1]['choice'].present? }
      end
      pdf.move_down 8
    end
    pdf.move_down 4
  end

  def acknowledgment(pdf, sheet)
    pdf.text ACKNOWLEDGE[sheet], size: 8.5, color: INK, leading: 1.5
    pdf.move_down 14
  end

  # A row per signer: signature line, printed name, date line.
  def signatures(pdf, sheet)
    list = signers
    needed = list.size * 40
    pdf.start_new_page if pdf.cursor < needed
    w = pdf.bounds.width
    sig_w = w * 0.62
    date_x = w * 0.70
    date_w = w * 0.30
    list.each do |s|
      line_y = pdf.cursor - 22
      pdf.stroke_color INK
      pdf.stroke_line [0, line_y], [sig_w, line_y]
      pdf.stroke_line [date_x, line_y], [date_x + date_w, line_y]
      spot(pdf, sheet, s[:key], 'signature', 0, line_y + 20, sig_w, 20)
      spot(pdf, sheet, s[:key], 'date', date_x, line_y + 20, date_w, 20)
      pdf.move_cursor_to line_y - 3
      pdf.text_box [s[:label], s[:name].presence].compact.join(': '), at: [0, pdf.cursor], width: sig_w, size: 7.5, color: MUTED
      pdf.text_box 'Date', at: [date_x, pdf.cursor], width: date_w, size: 7.5, color: MUTED
      pdf.move_down 16
    end
  end

  # x/top in points within the margin box, converted to the page.
  def spot(pdf, sheet, signer, kind, x, top, width, height)
    abs_x = pdf.bounds.absolute_left + x
    abs_top = pdf.bounds.absolute_bottom + top
    @spots << placement(pdf.page_number, sheet, signer, kind, abs_x, abs_top, width, height)
  end

  # Absolute points (bottom-left origin) to agreement placement percentages.
  def placement(page, sheet, signer, kind, abs_x, abs_top, width, height)
    { 'page' => page - 1, 'sheet' => sheet, 'signer' => signer, 'kind' => kind,
      'x' => (abs_x / PAGE_W * 100).round(2), 'y' => ((PAGE_H - abs_top) / PAGE_H * 100).round(2),
      'width' => (width / PAGE_W * 100).round(2), 'height' => (height / PAGE_H * 100).round(2) }
  end

  def quantity(row)
    q = row['quantity'].to_s('F').sub(/\.0\z/, '')
    row['unit'] == 'each' ? q : "#{q} #{row['unit'].upcase}"
  end

  def price(row)
    return 'To follow' if row['price'].nil?
    return 'Standard' if row['status'] == 'Standard'
    return 'No charge' if row['price'].zero?

    money(row['price'])
  end

  def money(v)
    return 'Not priced' if v.nil?

    whole, decimal = format('%.2f', v.to_f.abs).split('.')
    "#{'-' if v.to_f.round(2).negative?}$#{whole.reverse.scan(/\d{1,3}/).join(',').reverse}.#{decimal}"
  end

  def escape(text) = text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
end
