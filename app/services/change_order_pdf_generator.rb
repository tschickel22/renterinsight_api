# frozen_string_literal: true

# A factory change order as a PDF (backlog E52): what changes on the order
# the factory already has, the production status the dealer reports, and the
# cost difference unless the dealer leaves prices off the factory PO.
class ChangeOrderPdfGenerator
  CHANGE = { 'add' => 'Add', 'remove' => 'Remove', 'quantity' => 'Change quantity', 'cost' => 'Price correction',
             'substitute' => 'Substitute' }.freeze

  def initialize(change_order)
    @co = change_order
    @po = change_order.purchase_order
    @company = @po.company
    @hide_prices = @po.hide_prices_for_factory?
  end

  def generate
    pdf = Prawn::Document.new(page_size: 'LETTER', margin: [50, 50, 60, 50])
    pdf.text @company.name, size: 16, style: :bold
    pdf.move_up 18
    pdf.text 'CHANGE ORDER', size: 18, style: :bold, align: :right
    pdf.text @co.label, size: 11, align: :right
    pdf.text "To PO #{@po.po_number}, dated #{@po.order_date&.strftime('%b %-d, %Y')}", size: 9, align: :right
    pdf.text "Date #{(@co.emailed_at || @co.created_at).strftime('%b %-d, %Y')}", size: 9, align: :right
    pdf.move_down 12
    vendor = @po.manufacturer&.name || @po.supplier&.name
    to = ["To: #{vendor}", @po.order_contact[:name].presence, @po.order_contact[:email].presence].compact
    to << "Deal #{@po.deal.deal_number}" if @po.deal&.deal_number.present?
    pdf.text to.join("\n"), size: 10
    pdf.move_down 10
    pdf.text "Production status: #{@co.production_warning}", size: 10, style: :bold
    pdf.move_down 12
    lines(pdf) if @co.lines.any?
    colors(pdf) if @co.colors.any?
    unless @hide_prices
      pdf.text "Cost difference: #{money(@co.cost_delta)}", size: 11, style: :bold, align: :right
      pdf.move_down 10
    end
    if @co.notes.present?
      pdf.text 'Notes', style: :bold, size: 10
      pdf.text @co.notes, size: 9
      pdf.move_down 10
    end
    pdf.move_down 20
    pdf.text 'Please confirm this change, or tell us what it costs or why it cannot be made.', size: 9, color: '555555'
    pdf.render
  end

  private

  def money(v)
    number = v.to_f
    whole, decimal = format('%.2f', number.abs).split('.')
    "#{'-' if number.round(2).negative?}$#{whole.reverse.scan(/\d{1,3}/).join(',').reverse}.#{decimal}"
  end

  def qty(v) = v.nil? ? '' : v.to_d.to_s('F').sub(/\.0\z/, '')

  def lines(pdf)
    head = %w[Change Item Code Qty]
    head += ['Cost difference'] unless @hide_prices
    rows = [head]
    @co.lines.each do |l|
      item = l['change'] == 'substitute' ? "#{l['description']} (was #{l['was']})" : l['description'].to_s
      quantity = l['change'] == 'quantity' ? "#{qty(l['quantity_from'])} to #{qty(l['quantity_to'])}" : qty(l['quantity_to'] || l['quantity_from'])
      row = [CHANGE[l['change']] || l['change'].to_s, item, l['code'].to_s, quantity]
      row << money(l['cost_delta']) unless @hide_prices
      rows << row
    end
    pdf.table(rows, header: true, width: pdf.bounds.width, cell_style: { size: 9, padding: [5, 5], border_color: 'DDDDDD' }) do |t|
      t.row(0).font_style = :bold
      t.row(0).background_color = 'F3F4F6'
    end
    pdf.move_down 12
  end

  def colors(pdf)
    pdf.text 'Colors and finishes', style: :bold, size: 11
    pdf.move_down 4
    rows = [%w[Set From To Code]]
    @co.colors.each do |c|
      rows << [c['set'].to_s, c['from'].presence || 'Not chosen', c['to'].presence || (c['skipped'] ? 'Not on this home' : 'Not chosen yet'), c['code'].to_s]
    end
    pdf.table(rows, header: true, width: pdf.bounds.width, cell_style: { size: 9, padding: [4, 5], border_color: 'DDDDDD' }) do |t|
      t.row(0).font_style = :bold
      t.row(0).background_color = 'F3F4F6'
    end
    pdf.move_down 12
  end
end
