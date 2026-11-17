# frozen_string_literal: true

# The installer's scope sheet from a quote (ProjectQuoteDetails). No prices.
class ProjectQuoteDetailsPdf
  def initialize(project, quote, lines)
    @project = project
    @quote = quote
    @lines = lines
  end

  def render
    project = @project
    quote = @quote
    lines = @lines
    Prawn::Document.new(page_size: 'LETTER', margin: [50, 50, 60, 50]) do |pdf|
      pdf.font_size 10
      pdf.text project.company&.name.to_s, size: 9, color: '666666'
      pdf.text 'Quote details', size: 18, style: :bold
      pdf.move_down 4
      pdf.text "From quote #{quote.quote_number}. Prices are not shown.", size: 9, color: '666666'
      pdf.move_down 12

      facts = [
        ['Project', [project.project_number, project.name].compact.join('  ')],
        ['Customer', project.customer_display_name],
        ['Home', project.home_display_name],
        ['Delivery address', project.delivery_address_display.presence || quote_address(quote)]
      ].reject { |_, v| v.blank? }
      pdf.table(facts, cell_style: { borders: [], padding: [2, 8, 2, 0] }, column_widths: { 0 => 110 }) do
        column(0).font_style = :bold
      end
      pdf.move_down 14

      if lines.empty?
        pdf.text 'This quote has no items.', style: :italic
      else
        rows = [['#', 'Item', 'Category', 'Qty', 'Notes']]
        lines.each_with_index do |l, i|
          rows << [(i + 1).to_s, l[:description], l[:category].to_s.capitalize, qty(l[:quantity]), l[:notes].to_s]
        end
        pdf.table(rows, header: true, width: pdf.bounds.width,
                        column_widths: { 0 => 24, 2 => 80, 3 => 36 },
                        cell_style: { size: 9, padding: [5, 6], border_color: 'DDDDDD' }) do
          row(0).font_style = :bold
          row(0).background_color = 'F3F4F6'
        end
      end

      pdf.number_pages 'Page <page> of <total>', at: [pdf.bounds.right - 100, -20], width: 100, align: :right, size: 8
    end.render
  end

  private

  def qty(q)
    f = q.to_f
    f == f.to_i ? f.to_i.to_s : f.to_s
  end

  def quote_address(quote)
    [quote.try(:delivery_street), quote.try(:delivery_city), quote.try(:delivery_state), quote.try(:delivery_zip)]
      .compact.reject(&:blank?).join(', ')
  end
end
