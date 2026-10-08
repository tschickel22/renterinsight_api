# frozen_string_literal: true

# A purchase order as a PDF, for emailing to the manufacturer or supplier
# (backlog E51). Dealer cost only: it is the dealer's order to the factory.
class PurchaseOrderPdfGenerator
  def initialize(po)
    @po = po
    @company = po.company
    @location = po.location
    # The dealer's choice (Settings, TrueBuild pricing): the factory prices its own order.
    @hide_prices = po.hide_prices_for_factory?
  end

  def generate
    pdf = Prawn::Document.new(page_size: 'LETTER', margin: [50, 50, 60, 50])
    header(pdf)
    pdf.move_down 16
    parties(pdf)
    pdf.move_down 16
    lines(pdf)
    if @po.colors.any?
      pdf.move_down 14
      colors(pdf)
    end
    unless @hide_prices
      pdf.move_down 12
      totals(pdf)
    end
    if @po.notes.present?
      pdf.move_down 16
      pdf.text 'Notes', style: :bold, size: 10
      pdf.text @po.notes, size: 9
    end
    pdf.render
  end

  private

  def money(v)
    number = v.to_f
    whole, decimal = format('%.2f', number.abs).split('.')
    "#{'-' if number.round(2).negative?}$#{whole.reverse.scan(/\d{1,3}/).join(',').reverse}.#{decimal}"
  end

  def header(pdf)
    title = @po.factory_home? ? 'HOME ORDER' : 'PURCHASE ORDER'
    pdf.text @company.name, size: 16, style: :bold
    from = @location || @company.locations.where(active: true).first
    addr = [from&.try(:address_line1), [from&.try(:city), from&.try(:state), from&.try(:zip_code)].compact.join(' ')].compact.reject(&:blank?)
    pdf.text addr.join(', '), size: 9 if addr.any?
    pdf.move_up 30
    pdf.text title, size: 18, style: :bold, align: :right
    pdf.text "PO #{@po.po_number}", size: 11, align: :right
    pdf.text "Date #{@po.order_date&.strftime('%b %-d, %Y')}", size: 9, align: :right
    pdf.text "Needed by #{@po.expected_delivery_date.strftime('%b %-d, %Y')}", size: 9, align: :right if @po.expected_delivery_date
  end

  def parties(pdf)
    vendor = @po.manufacturer&.name || @po.supplier&.name
    ship = [@po.ship_to_name, @po.ship_to_address1, @po.ship_to_address2,
            [@po.ship_to_city, @po.ship_to_state, @po.ship_to_zip].compact.join(' ')].reject(&:blank?)
    left = ["To: #{vendor}", @po.order_contact[:name].presence, @po.order_contact[:email].presence].compact
    right = ['Ship to:', *ship]
    right << "Deal #{@po.deal.deal_number}" if @po.deal&.deal_number.present?
    pdf.table([[left.join("\n"), right.join("\n")]], width: pdf.bounds.width, cell_style: { borders: [], size: 10, padding: [2, 0] })
  end

  def lines(pdf)
    rows = [@hide_prices ? %w[Item Code Qty] : ['Item', 'Code', 'Qty', 'Unit cost', 'Total']]
    @po.lines.order(:line_number).each do |l|
      row = [l.part_name.to_s, l.part_number.to_s, l.quantity_ordered.to_d.to_s('F').sub(/\.0\z/, '')]
      row += [money(l.unit_cost), money(l.line_total)] unless @hide_prices
      rows << row
    end
    last = rows.first.size - 1
    pdf.table(rows, header: true, width: pdf.bounds.width, cell_style: { size: 9, padding: [5, 5], border_color: 'DDDDDD' }) do |t|
      t.row(0).font_style = :bold
      t.row(0).background_color = 'F3F4F6'
      t.columns(2..last).align = :right
    end
  end

  # Every color and finish set on the model, with the pick; an unpicked one
  # is flagged so the factory confirms it rather than guessing.
  def colors(pdf)
    pdf.text 'Colors and finishes', style: :bold, size: 11
    pdf.move_down 4
    rows = [%w[Set Choice Code]]
    @po.colors.each do |c|
      choice = c['choice'].presence || (c['skipped'] ? 'Not on this home' : 'Not chosen yet: please confirm')
      rows << [c['set'].to_s, choice, c['code'].to_s]
    end
    pdf.table(rows, header: true, width: pdf.bounds.width, cell_style: { size: 9, padding: [4, 5], border_color: 'DDDDDD' }) do |t|
      t.row(0).font_style = :bold
      t.row(0).background_color = 'F3F4F6'
    end
  end

  def totals(pdf)
    data = [['Subtotal', money(@po.subtotal)]]
    data << ['Shipping', money(@po.shipping_cost)] if @po.shipping_cost.to_f.positive?
    data << ['Tax', money(@po.tax_amount)] if @po.tax_amount.to_f.positive?
    data << ['Total', money(@po.total_amount)]
    pdf.table(data, position: :right, width: 220, cell_style: { borders: [], size: 10, padding: [3, 6] }) do |t|
      t.columns(1).align = :right
      t.row(-1).font_style = :bold
    end
  end
end
