# frozen_string_literal: true

require 'prawn'
require 'prawn/table'

class QuotePdfGenerator
  def initialize(quote)
    @quote = quote
    @company = ::Company.first # Get the first company (single-tenant for now)
    @settings = load_company_settings
    @pdf = Prawn::Document.new(page_size: 'LETTER', margin: 40)
  end

  def generate
    add_header
    add_quote_info
    add_line_items
    add_totals
    add_terms if @quote.custom_fields&.dig('termsConditions').present?
    add_footer
    
    @pdf.render
  end

  private
  
  def load_company_settings
    return {} unless @company
    
    # Load settings from Setting model
    quotes_setting = ::Setting.get('Company', @company.id, 'quotes', {})
    branding_setting = ::Setting.get('Company', @company.id, 'branding', {})
    
    {
      'quotes' => quotes_setting || {},
      'branding' => branding_setting || {}
    }
  end

  def add_header
    # Save the top position for reference
    header_top = @pdf.cursor
    
    # Company logo (if available) - check quotes settings first, then branding
    logo_url = @settings.dig('quotes', 'logoUrl') || @settings.dig('branding', 'logo')
    
    Rails.logger.info "PDF Generator - Logo URL: #{logo_url.inspect}"
    Rails.logger.info "PDF Generator - Settings: #{@settings.inspect}"
    
    logo_height = 0
    
    # Display logo if available
    if logo_url.present?
      begin
        # For HTTP URLs, download the image temporarily
        require 'open-uri'
        require 'tempfile'
        
        # Handle different URL formats
        if logo_url.start_with?('/')
          # Relative path - load from public directory
          file_path = Rails.root.join('public', logo_url.sub(/^\//, ''))
          
          if File.exist?(file_path)
            # Place logo in a bounding box on the left
            @pdf.bounding_box([0, header_top], width: 120) do
              @pdf.image file_path.to_s, width: 100
            end
            logo_height = 80 # Approximate logo height with padding
            Rails.logger.info "PDF Generator - Logo loaded from relative path: #{file_path}"
          else
            Rails.logger.warn "PDF Generator - File not found at relative path: #{file_path}"
          end
        elsif logo_url.start_with?('http://localhost', 'http://127.0.0.1')
          # For localhost URLs, convert to file path
          uri = URI.parse(logo_url)
          file_path = Rails.root.join('public', uri.path.sub(/^\//, ''))
          
          if File.exist?(file_path)
            @pdf.bounding_box([0, header_top], width: 120) do
              @pdf.image file_path.to_s, width: 100
            end
            logo_height = 80
            Rails.logger.info "PDF Generator - Logo loaded from localhost URL: #{file_path}"
          else
            Rails.logger.warn "PDF Generator - Local file not found: #{file_path}"
          end
        elsif logo_url.start_with?('http')
          # For external HTTP URLs
          tempfile = Tempfile.new(['logo', '.png'])
          tempfile.binmode
          URI.open(logo_url) { |f| tempfile.write(f.read) }
          tempfile.rewind
          
          @pdf.bounding_box([0, header_top], width: 120) do
            @pdf.image tempfile.path, width: 100
          end
          logo_height = 80
          
          tempfile.close
          tempfile.unlink
          Rails.logger.info "PDF Generator - Logo loaded from URL: #{logo_url}"
        else
          Rails.logger.warn "PDF Generator - Unsupported logo URL format: #{logo_url}"
        end
      rescue => e
        Rails.logger.error "PDF Generator - Failed to load logo: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        # Continue without logo
      end
    else
      Rails.logger.info "PDF Generator - No logo URL found"
    end

    # Company info - position to the right of logo or at top if no logo
    company_left_margin = logo_height > 0 ? 130 : 0
    
    @pdf.bounding_box([company_left_margin, header_top], width: @pdf.bounds.width - company_left_margin) do
      company_name = @settings.dig('quotes', 'companyName') || @company&.name || 'Company Name'
      @pdf.text company_name, size: 20, style: :bold
      
      if @settings.dig('quotes', 'companyAddress').present?
        @pdf.move_down 5
        @pdf.font_size(9) do
          @pdf.text @settings['quotes']['companyAddress']
          
          city_state_zip = [
            @settings['quotes']['companyCity'],
            @settings['quotes']['companyState'],
            @settings['quotes']['companyZip']
          ].compact.join(' ')
          
          @pdf.text city_state_zip if city_state_zip.present?
          @pdf.text "Phone: #{@settings['quotes']['companyPhone']}" if @settings['quotes']['companyPhone'].present?
          @pdf.text "Email: #{@settings['quotes']['companyEmail']}" if @settings['quotes']['companyEmail'].present?
          @pdf.text "Web: #{@settings['quotes']['companyWebsite']}" if @settings['quotes']['companyWebsite'].present?
        end
      end
    end

    # Quote number and status (top right) - use absolute positioning
    @pdf.bounding_box([@pdf.bounds.right - 200, @pdf.bounds.top], width: 200) do
      @pdf.text 'QUOTE', size: 10, align: :right, style: :bold
      @pdf.text @quote.quote_number, size: 18, align: :right, style: :bold
      @pdf.move_down 5
      @pdf.text "Date: #{@quote.created_at.strftime('%B %d, %Y')}", size: 9, align: :right
      @pdf.text "Valid Until: #{@quote.valid_until.strftime('%B %d, %Y')}", size: 9, align: :right
    end

    # Move cursor down past the header
    @pdf.move_cursor_to(header_top - [logo_height, 100].max)
    @pdf.move_down 20
    @pdf.stroke_horizontal_rule
    @pdf.move_down 20
  end

  def add_quote_info
    # Client information
    data = []
    
    if @quote.account
      data << ['Bill To (Account):', @quote.account.name]
    end
    
    if @quote.contact
      contact_name = "#{@quote.contact.first_name} #{@quote.contact.last_name}".strip
      data << ['Attention (Contact):', contact_name]
    end
    
    # Custom fields
    if @quote.custom_fields
      data << ['Reference/PO Number:', @quote.custom_fields['referenceNumber']] if @quote.custom_fields['referenceNumber'].present?
      data << ['Expected Delivery:', format_date(@quote.custom_fields['deliveryDate'])] if @quote.custom_fields['deliveryDate'].present?
      data << ['Payment Terms:', format_payment_terms(@quote.custom_fields['paymentTerms'], @quote.custom_fields['paymentTermsOther'])] if @quote.custom_fields['paymentTerms'].present?
    end

    if data.any?
      @pdf.table(data, cell_style: { borders: [], padding: [2, 5, 2, 5] }, column_widths: [150, 350]) do
        columns(0).font_style = :bold
        columns(0).text_color = '666666'
      end
      @pdf.move_down 15
    end

    # Customer notes
    if @quote.custom_fields&.dig('customerNotes').present?
      @pdf.fill_color 'E3F2FD'
      @pdf.fill_rectangle [0, @pdf.cursor], @pdf.bounds.width, 60
      @pdf.fill_color '000000'
      
      @pdf.bounding_box([5, @pdf.cursor - 5], width: @pdf.bounds.width - 10) do
        @pdf.text 'Notes:', size: 9, style: :bold
        @pdf.move_down 3
        @pdf.text @quote.custom_fields['customerNotes'], size: 9
      end
      
      @pdf.move_down 65
    end
  end

  def add_line_items
    @pdf.text 'Line Items', size: 14, style: :bold
    @pdf.move_down 10

    items_data = [['Description', 'Quantity', 'Unit Price', 'Discount', 'Total']]
    
    @quote.items.each do |item|
      discount_text = if item['discount'].to_f > 0
        item['discountType'] == 'percentage' ? "#{item['discount']}%" : format_currency(item['discount'])
      else
        '-'
      end

      items_data << [
        item['description'],
        item['quantity'].to_s,
        format_currency(item['unitPrice'] || item['unit_price']),
        discount_text,
        format_currency(item['total'])
      ]
    end

    @pdf.table(items_data, header: true, width: @pdf.bounds.width) do
      row(0).font_style = :bold
      row(0).background_color = 'F5F5F5'
      columns(1..4).align = :right
      self.cell_style = { padding: [5, 10] }
    end

    @pdf.move_down 20
  end

  def add_totals
    totals_data = []
    
    totals_data << ['Items Subtotal:', format_currency(@quote.subtotal)]
    
    # Overall discount
    if @quote.custom_fields&.dig('overallDiscount').to_f > 0
      discount_label = if @quote.custom_fields['discountType'] == 'percentage'
        "Overall Discount (#{@quote.custom_fields['discountValue']}%):"
      else
        'Overall Discount (Fixed):'
      end
      totals_data << [discount_label, "-#{format_currency(@quote.custom_fields['overallDiscount'])}"]
    end
    
    # Shipping
    if @quote.custom_fields&.dig('shippingCost').to_f > 0
      totals_data << ['Shipping/Delivery:', format_currency(@quote.custom_fields['shippingCost'])]
    end
    
    # Calculate subtotal after discount
    subtotal_after = @quote.subtotal.to_f - 
                     @quote.custom_fields&.dig('overallDiscount').to_f + 
                     @quote.custom_fields&.dig('shippingCost').to_f
    totals_data << ['Subtotal (after discount):', format_currency(subtotal_after)]
    
    totals_data << ['Tax:', format_currency(@quote.tax)]
    totals_data << ['Total:', format_currency(@quote.total)]
    
    # Deposit
    if @quote.custom_fields&.dig('depositRequired') && @quote.custom_fields&.dig('depositAmount').to_f > 0
      deposit_label = if @quote.custom_fields['depositType'] == 'percentage'
        "Deposit Required (#{@quote.custom_fields['depositValue']}%):"
      else
        'Deposit Required (Fixed):'
      end
      totals_data << [deposit_label, format_currency(@quote.custom_fields['depositAmount'])]
    end

    @pdf.bounding_box([@pdf.bounds.right - 300, @pdf.cursor], width: 300) do
      @pdf.table(totals_data, cell_style: { borders: [], padding: [3, 10] }) do
        columns(0).align = :right
        columns(1).align = :right
        columns(1).font_style = :bold
        row(-1).size = 14 if totals_data.length > 1
        row(-1).background_color = 'F5F5F5' if totals_data.length > 1
      end
    end

    @pdf.move_down 30
  end

  def add_terms
    @pdf.text 'Terms & Conditions', size: 12, style: :bold
    @pdf.move_down 5
    
    @pdf.fill_color 'F5F5F5'
    @pdf.fill_rectangle [0, @pdf.cursor], @pdf.bounds.width, 80
    @pdf.fill_color '000000'
    
    @pdf.bounding_box([5, @pdf.cursor - 5], width: @pdf.bounds.width - 10) do
      @pdf.text @quote.custom_fields['termsConditions'], size: 8
    end
    
    @pdf.move_down 85
  end

  def add_footer
    @pdf.move_down 20
    @pdf.stroke_horizontal_rule
    @pdf.move_down 10
    
    @pdf.text 'Thank you for your business!', size: 10, align: :center, style: :italic
  end

  # Helper methods
  def format_currency(amount)
    "$#{sprintf('%.2f', amount.to_f)}"
  end

  def format_date(date_string)
    return '' unless date_string
    Date.parse(date_string).strftime('%B %d, %Y')
  rescue
    date_string
  end

  def format_payment_terms(terms, other = nil)
    case terms
    when 'net_30' then 'Net 30 Days'
    when 'net_15' then 'Net 15 Days'
    when 'due_on_receipt' then 'Due on Receipt'
    when 'cod' then 'Cash on Delivery'
    when '50_50' then '50% Deposit, 50% on Completion'
    when 'other' then other || 'Other'
    else terms
    end
  end

  def logo_path(url)
    # This is a simplified path resolver - adjust based on your storage setup
    # If using Active Storage or other cloud storage, you'd need to download it first
    if url.start_with?('http')
      # For remote URLs, you'd need to download the image first
      # This is a placeholder - implement based on your needs
      nil
    else
      Rails.root.join('public', url)
    end
  end
end
