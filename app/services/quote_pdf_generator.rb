# frozen_string_literal: true

require 'prawn'
require 'prawn/table'

class QuotePdfGenerator
  def initialize(quote)
    @quote = quote
    @company = quote.company
    @account = quote.account
    @contact = quote.contact
  end

  def generate
    pdf = Prawn::Document.new(page_size: 'LETTER', margin: 50)

    # Header with company logo/name
    add_header(pdf)
    pdf.move_down 30

    # Quote metadata
    add_quote_info(pdf)
    pdf.move_down 30

    # Line items table
    add_line_items(pdf)
    pdf.move_down 20

    # Totals
    add_totals(pdf)
    pdf.move_down 30

    # Notes
    add_notes(pdf) if @quote.notes.present?
    pdf.move_down 20

    # Footer
    add_footer(pdf)

    pdf.render
  end

  private

  def add_header(pdf)
    # Company name/logo
    pdf.font_size(24) do
      pdf.text @company.name, style: :bold
    end
    
    pdf.font_size(10) do
      pdf.text @company.phone if @company.phone.present?
      pdf.text @company.email if @company.email.present?
      pdf.text @company.website if @company.website.present?
    end
  end

  def add_quote_info(pdf)
    # Quote number and dates
    pdf.font_size(18) do
      pdf.text "Quote ##{@quote.quote_number || @quote.id}", style: :bold
    end
    
    pdf.move_down 15
    
    # Two-column layout for quote info
    pdf.font_size(10) do
      quote_data = [
        ['Quote Date:', @quote.created_at.strftime('%B %d, %Y')],
        ['Valid Until:', @quote.valid_until.strftime('%B %d, %Y')],
        ['Status:', @quote.status.titleize]
      ]
      
      customer_data = [
        ['Customer:', @account&.name || 'N/A'],
        ['Contact:', @contact ? "#{@contact.first_name} #{@contact.last_name}" : 'N/A'],
        ['Email:', @contact&.email || 'N/A'],
        ['Phone:', @contact&.phone || 'N/A']
      ]
      
      pdf.table([quote_data, customer_data].transpose, 
        width: pdf.bounds.width,
        column_widths: [pdf.bounds.width / 4, pdf.bounds.width / 4, pdf.bounds.width / 4, pdf.bounds.width / 4],
        cell_style: { borders: [], padding: [2, 5] }
      )
    end
  end

  def add_line_items(pdf)
    pdf.font_size(12) do
      pdf.text 'Line Items', style: :bold
    end
    
    pdf.move_down 10
    
    # Prepare table data
    items = @quote.items || []
    
    table_data = [
      ['Description', 'Qty', 'Unit Price', 'Discount', 'Total']
    ]
    
    items.each do |item|
      table_data << [
        item['description'] || '',
        item['quantity'] || 0,
        format_currency(item['unit_price'] || 0),
        format_currency(item['discount'] || 0),
        format_currency(item['total'] || 0)
      ]
    end
    
    pdf.table(table_data,
      width: pdf.bounds.width,
      header: true,
      row_colors: ['FFFFFF', 'F5F5F5'],
      cell_style: { borders: [:bottom], border_color: 'CCCCCC', padding: [8, 10] }
    ) do
      row(0).font_style = :bold
      row(0).background_color = 'E5E5E5'
      columns(1..4).align = :right
    end
  end

  def add_totals(pdf)
    # Right-aligned totals
    totals_data = [
      ['Subtotal:', format_currency(@quote.subtotal)],
      ['Tax:', format_currency(@quote.tax)],
      ['', ''],
      ['Total:', format_currency(@quote.total)]
    ]
    
    pdf.table(totals_data,
      position: :right,
      width: 250,
      cell_style: { borders: [], padding: [5, 10] }
    ) do
      columns(0).font_style = :bold
      columns(1).align = :right
      row(3).font_style = :bold
      row(3).size = 14
      row(3).borders = [:top]
      row(3).border_width = 2
    end
  end

  def add_notes(pdf)
    pdf.font_size(12) do
      pdf.text 'Notes:', style: :bold
    end
    
    pdf.move_down 5
    
    pdf.font_size(10) do
      pdf.text @quote.notes
    end
  end

  def add_footer(pdf)
    pdf.move_down 40
    
    pdf.font_size(8) do
      pdf.text_box 'Thank you for your business!',
        at: [0, 50],
        width: pdf.bounds.width,
        align: :center,
        style: :italic
    end
  end

  def format_currency(amount)
    "$#{sprintf('%.2f', amount)}"
  end
end
