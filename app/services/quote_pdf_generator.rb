# frozen_string_literal: true

require 'prawn'
require 'prawn/table'
require 'net/http'

class QuotePdfGenerator
  def initialize(quote)
    @quote = quote
    @company = quote.company
    @account = quote.account
    @contact = quote.contact
    @location = quote.location
  end

  def generate
    brand = resolve_branding
    accent = brand[:accent]

    pdf = Prawn::Document.new(page_size: 'LETTER', margin: [50, 50, 80, 50])

    add_header(pdf, brand)
    pdf.move_down 20
    add_quote_info(pdf, accent)
    pdf.move_down 20
    add_line_items(pdf, accent)
    pdf.move_down 20
    add_totals(pdf, accent)

    if @quote.notes.present?
      pdf.move_down 25
      add_notes(pdf, accent)
    end

    # Terms & Conditions (from dedicated column or custom_fields fallback)
    terms_text = @quote.terms.presence || @quote.custom_fields&.dig('termsConditions').presence
    if terms_text.present?
      pdf.move_down 20
      add_terms(pdf, accent, terms_text)
    end

    add_footer(pdf)

    pdf.render
  end

  private

  # ── BRANDING RESOLUTION (same pattern as invoices) ──
  def resolve_branding
    loan_settings = @company.loan_settings || {}
    source_pref = loan_settings['invoice_branding_source'] || 'location'
    location = @location

    # Resolve branding settings (location → company fallback)
    branding = {}
    if source_pref == 'location' && location.present?
      branding = Setting.get('Location', location.id, 'branding') rescue {} || {}
    end
    if branding.blank?
      branding = Setting.get('Company', @company.id, 'branding') rescue {} || {}
    end
    branding ||= {}

    # Logo URL
    logo_url = branding['logo'].presence

    # Address from location or first active location
    addr_source = location || @company.locations.where(active: true).first
    address = {
      name: source_pref == 'company' ? @company.name : (location&.name || @company.name),
      phone: addr_source&.phone,
      email: addr_source&.email,
      line1: addr_source&.respond_to?(:address_line1) ? addr_source.address_line1 : nil,
      city: addr_source&.city,
      state: addr_source&.state,
      zip: addr_source&.respond_to?(:zip_code) ? addr_source.zip_code : nil
    }

    # Accent color (strip # for Prawn)
    accent = (branding['primaryColor'] || branding['primary_color'] || '#2563EB').to_s.delete('#')

    { logo_url: logo_url, address: address, accent: accent, company_name: @company.name }
  end

  # ── LOGO LOADING ──
  def load_logo(url)
    return nil unless url.present?

    # Try local file first (for /uploads/ paths)
    if url.include?('/uploads/')
      relative_path = url.sub(%r{^https?://[^/]+}, '')
      upload_base = ENV['UPLOAD_PATH'] || Rails.root.join('public', 'uploads')
      local_path = File.join(upload_base.to_s.sub(/\/uploads$/, ''), relative_path.sub(/^\//, ''))
      alt_path = File.join(upload_base.to_s, relative_path.sub(%r{^/uploads/}, ''))

      return File.binread(local_path) if File.exist?(local_path)
      return File.binread(alt_path) if File.exist?(alt_path)
    end

    # HTTP download with redirect following
    return nil unless url.start_with?('http://', 'https://')
    uri = URI.parse(url)
    redirects = 0
    loop do
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = 5
      http.read_timeout = 10
      response = http.request(Net::HTTP::Get.new(uri.request_uri))
      case response
      when Net::HTTPSuccess then return response.body
      when Net::HTTPRedirection
        redirects += 1
        return nil if redirects > 3
        uri = URI.parse(response['location'])
      else return nil
      end
    end
  rescue => e
    Rails.logger.warn "[QuotePDF] Failed to load logo: #{e.message}"
    nil
  end

  # ── HEADER ──
  def add_header(pdf, brand)
    header_top = pdf.cursor
    accent = brand[:accent]
    addr = brand[:address]

    # Logo or company name (left)
    logo_loaded = false
    if brand[:logo_url].present?
      begin
        logo_data = load_logo(brand[:logo_url])
        if logo_data
          pdf.image StringIO.new(logo_data), fit: [150, 60], position: :left
          logo_loaded = true
        end
      rescue => e
        Rails.logger.warn "[QuotePDF] Logo render error: #{e.message}"
      end
    end
    pdf.text brand[:company_name], size: 18, style: :bold unless logo_loaded

    logo_bottom = pdf.cursor

    # Address block (right-aligned)
    pdf.bounding_box([pdf.bounds.right - 200, header_top], width: 200) do
      pdf.text addr[:name], size: 11, style: :bold, align: :right
      pdf.text addr[:phone], size: 9, align: :right if addr[:phone].present?
      pdf.text addr[:line1], size: 9, align: :right if addr[:line1].present?
      city_state = [addr[:city], addr[:state], addr[:zip]].compact.join(', ')
      pdf.text city_state, size: 9, align: :right if city_state.present?
      pdf.text addr[:email], size: 9, align: :right if addr[:email].present?
    end

    pdf.move_cursor_to [logo_bottom, pdf.cursor].min - 5
    pdf.stroke_color accent
    pdf.line_width = 1.5
    pdf.stroke_horizontal_rule
    pdf.stroke_color '000000'
  end

  # ── QUOTE INFO (4 columns, no overlap) ──
  def add_quote_info(pdf, accent)
    meta_top = pdf.cursor
    w = pdf.bounds.width

    # Column 1: Billed To (35%)
    pdf.bounding_box([0, meta_top], width: w * 0.35) do
      pdf.text 'Billed To', size: 8, color: accent
      if @contact
        pdf.text "#{@contact.first_name} #{@contact.last_name}".strip, size: 11, style: :bold
        pdf.text @contact.email, size: 9 if @contact.email.present?
        pdf.text @contact.phone, size: 9 if @contact.phone.present?
      elsif @account
        pdf.text @account.name, size: 11, style: :bold
      end
    end

    # Column 2: Dates (20%)
    pdf.bounding_box([w * 0.35, meta_top], width: w * 0.20) do
      pdf.text 'Quote Date', size: 8, color: accent
      pdf.text @quote.created_at.strftime('%m/%d/%Y'), size: 10
      if @quote.valid_until.present?
        pdf.move_down 8
        pdf.text 'Valid Until', size: 8, color: accent
        pdf.text @quote.valid_until.strftime('%m/%d/%Y'), size: 10
      end
    end

    # Column 3: Quote Number (20%)
    pdf.bounding_box([w * 0.55, meta_top], width: w * 0.20) do
      pdf.text 'Quote Number', size: 8, color: accent
      pdf.text (@quote.quote_number || "##{@quote.id}"), size: 10, style: :bold
    end

    # Column 4: Total (25%, right-aligned)
    pdf.bounding_box([w * 0.75, meta_top], width: w * 0.25) do
      pdf.text 'Quote Total', size: 8, color: accent, align: :right
      pdf.text format_currency(@quote.total || 0), size: 20, style: :bold, align: :right
    end

    pdf.move_cursor_to meta_top - 70
  end

  # ── LINE ITEMS ──
  def add_line_items(pdf, accent)
    items = @quote.items || []
    return pdf.text('No line items', size: 10, color: '999999', style: :italic) if items.empty?

    # Check if ANY item has a non-zero discount
    has_discounts = items.any? do |item|
      d = (item['discount'] || item['Discount'] || 0).to_f
      d > 0
    end

    # Build header row based on whether discounts exist
    if has_discounts
      table_data = [['Description', 'Qty', 'Unit Price', 'Discount', 'Total']]
    else
      table_data = [['Description', 'Qty', 'Unit Price', 'Total']]
    end

    items.each do |item|
      desc = item['description'] || item['name'] || ''
      qty = item['quantity'] || item['qty'] || 1
      price = item['unit_price'] || item['unitPrice'] || item['rate'] || 0
      discount = (item['discount'] || 0).to_f
      total = item['total'] || item['line_total'] || item['lineTotal'] || 0

      # Add taxable indicator
      taxable = item['taxable'] == true || item['taxable'] == 'true'
      desc += ' +Tax' if taxable

      row = [desc, qty.to_s, format_currency(price)]
      row << format_currency(discount) if has_discounts
      row << format_currency(total)
      table_data << row

      # Add item notes as a sub-row if present
      item_notes = item['notes'] || item['Notes'] || ''
      if item_notes.present?
        col_span = has_discounts ? 5 : 4
        table_data << [{ content: item_notes, colspan: col_span, text_color: '666666', font_style: :italic, size: 8 }]
      end
    end

    num_cols = has_discounts ? 5 : 4
    right_cols = has_discounts ? (1..4) : (1..3)

    pdf.table(table_data, header: true, width: pdf.bounds.width,
              cell_style: { padding: [8, 6], size: 10, border_width: 0.5, border_color: 'DDDDDD' }) do |t|
      t.row(0).font_style = :bold
      t.row(0).text_color = 'FFFFFF'
      t.row(0).background_color = accent
      t.row(0).border_color = accent
      t.columns(right_cols).align = :right
    end
  end

  # ── TOTALS ──
  def add_totals(pdf, accent)
    cf = @quote.custom_fields || {}
    overall_discount = (cf['overallDiscount'] || cf['overall_discount'] || 0).to_f
    shipping_cost = (cf['shippingCost'] || cf['shipping_cost'] || 0).to_f
    deposit_required = cf['depositRequired'] || cf['deposit_required']
    deposit_amount = (cf['depositAmount'] || cf['deposit_amount'] || 0).to_f

    totals_data = []

    # Items subtotal (before overall discount)
    items_subtotal = (@quote.subtotal || 0).to_f + overall_discount - shipping_cost
    if overall_discount > 0 || shipping_cost > 0
      totals_data << ['Items Subtotal', format_currency(items_subtotal)]
    end

    # Overall discount
    if overall_discount > 0
      discount_label = 'Overall Discount'
      dv = cf['discountValue'] || cf['discount_value']
      dt = cf['discountType'] || cf['discount_type']
      if dt == 'percentage' && dv.present?
        discount_label = "Discount (#{dv}%)"
      end
      totals_data << [discount_label, "-#{format_currency(overall_discount)}"]
    end

    # Shipping
    if shipping_cost > 0
      totals_data << ['Shipping/Delivery', format_currency(shipping_cost)]
    end

    totals_data << ['Subtotal', format_currency(@quote.subtotal || 0)]
    totals_data << ['Tax', format_currency(@quote.tax || 0)]
    totals_data << ['Total', format_currency(@quote.total || 0)]

    # Deposit
    if deposit_required && deposit_amount > 0
      totals_data << ['Deposit Required', format_currency(deposit_amount)]
    end

    pdf.table(totals_data, position: :right, width: 250,
              cell_style: { borders: [], padding: [6, 8], size: 10 }) do |t|
      t.columns(0).font_style = :bold
      t.columns(1).align = :right
      # Style the Total row (second to last, or last if no deposit)
      total_row_idx = deposit_required && deposit_amount > 0 ? -2 : -1
      t.row(total_row_idx).font_style = :bold
      t.row(total_row_idx).size = 14
      t.row(total_row_idx).borders = [:top]
      t.row(total_row_idx).border_width = 2
      t.row(total_row_idx).border_color = accent
    end
  end

  # ── NOTES ──
  def add_notes(pdf, accent)
    pdf.text 'Notes', size: 11, style: :bold, color: accent
    pdf.move_down 5
    pdf.text @quote.notes, size: 10
  end

  # ── TERMS & CONDITIONS ──
  def add_terms(pdf, accent, terms_text)
    pdf.text 'Terms & Conditions', size: 11, style: :bold, color: accent
    pdf.move_down 5
    pdf.text terms_text, size: 8, color: '444444'
  end

  # ── FOOTER ──
  def add_footer(pdf)
    pdf.repeat(:all) do
      pdf.bounding_box([0, -25], width: pdf.bounds.width, height: 20) do
        pdf.font_size(8) { pdf.text 'Thank you for your business!', align: :center, style: :italic, color: '999999' }
      end
    end
    pdf.number_pages 'Page <page> of <total>', at: [pdf.bounds.right - 150, -45], align: :right, size: 8, color: '999999'
  end

  def format_currency(amount)
    number = amount.to_f
    whole, decimal = sprintf('%.2f', number).split('.')
    whole_with_commas = whole.reverse.scan(/\d{1,3}/).join(',').reverse
    "$#{whole_with_commas}.#{decimal}"
  end
end
