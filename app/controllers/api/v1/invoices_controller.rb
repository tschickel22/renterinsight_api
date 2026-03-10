class Api::V1::InvoicesController < ApplicationController
  before_action :set_company_scope
  before_action :set_invoice, only: [:show, :update, :destroy, :send_invoice, :send_sms, :mark_paid, :cancel, :pdf, :draw_schedule_pdf, :finalize]
  
  def index
    return unless authorize_action!('finance', 'read')
    
    invoices = @company.invoices.not_deleted
    
    # Apply location selector filter (if user selected a specific location)
    # Note: For invoices, we don't enforce strict RBAC location filtering
    # because invoices may not always have a location_id assigned
    invoices = invoices.for_current_location
    
    # IMPORTANT: Exclude future loan invoices by default (unless explicitly requested)
    # This prevents loan payment schedules from cluttering the invoice list
    unless params[:include_future_loan_invoices] == 'true'
      invoices = invoices.where(
        "(invoices.loan_id IS NULL) OR "\
        "(invoices.loan_id IS NOT NULL AND (invoices.status != 'draft' OR invoices.due_date <= ?))",
        Date.current
      )
    end
    
    # Filters
    if params[:status].present?
      if params[:status] == 'open'
        # Open invoices = all except paid and cancelled
        invoices = invoices.where.not(status: ['paid', 'cancelled'])
      else
        # Specific status filter
        invoices = invoices.where(status: params[:status])
      end
    end
    invoices = invoices.where(contact_id: params[:contact_id]) if params[:contact_id].present?
    invoices = invoices.where(deal_id: params[:deal_id]) if params[:deal_id].present?
    
    # Date range filter
    if params[:start_date].present?
      start_date = Date.parse(params[:start_date])
      invoices = invoices.where('invoice_date >= ?', start_date)
    end
    if params[:end_date].present?
      end_date = Date.parse(params[:end_date])
      invoices = invoices.where('invoice_date <= ?', end_date)
    end
    
    # Filter by account through contacts
    if params[:account_id].present?
      account_contact_ids = @company.contacts.where(account_id: params[:account_id]).pluck(:id)
      invoices = invoices.where(contact_id: account_contact_ids)
    end
    invoices = invoices.overdue if params[:overdue] == 'true'
    
    # Search
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      invoices = invoices.joins(:contact).where(
        'invoices.invoice_number ILIKE ? OR contacts.first_name ILIKE ? OR contacts.last_name ILIKE ?',
        search_term, search_term, search_term
      )
    end
    
    invoices = invoices.includes(:contact, :location, :invoice_items, :deal)
                       .order(invoice_date: :desc)
    
    # Serialize with recipient information
    render json: invoices.map { |invoice| serialize_invoice_list_item(invoice) }
  end
  
  def show
    return unless authorize_action!('finance', 'read')
    
    render json: serialize_invoice(@invoice)
  end
  
  def create
    return unless authorize_action!('finance', 'create')
    
    Rails.logger.info "📝 [Invoices#create] Received params: #{params.inspect}"
    Rails.logger.info "📝 [Invoices#create] Invoice items count: #{invoice_params[:invoice_items_attributes]&.length || 0}"
    
    invoice = @company.invoices.build(invoice_params)
    invoice.location_id ||= Current.location_id if Current.location_id.present?
    
    # RBAC fallback
    if invoice.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
      location_ids = permission_service.accessible_location_ids
      invoice.location_id = location_ids.first if location_ids.any?
    end
    
    if invoice.save
      Rails.logger.info "✅ [Invoices#create] Invoice saved with #{invoice.invoice_items.count} items"
      invoice.invoice_items.each_with_index do |item, idx|
        Rails.logger.info "   Item #{idx + 1}: #{item.description} - Qty: #{item.quantity} - Rate: #{item.rate}"
      end
      render json: invoice, include: [:contact, :invoice_items], status: :created
    else
      render json: { errors: invoice.errors }, status: :unprocessable_entity
    end
  end
  
  def update
    return unless authorize_action!('finance', 'update')
    
    if @invoice.update(invoice_params)
      render json: @invoice, include: [:contact, :invoice_items]
    else
      render json: { errors: @invoice.errors }, status: :unprocessable_entity
    end
  end
  
  def destroy
    return unless authorize_action!('finance', 'delete')
    
    @invoice.update(is_deleted: true)
    head :no_content
  end

  def pdf
    return unless authorize_action!('finance', 'read')
    
    pdf_content = generate_invoice_pdf(@invoice)
    
    send_data pdf_content,
      filename: "Invoice-#{@invoice.invoice_number}.pdf",
      type: 'application/pdf',
      disposition: 'attachment'
  end

  def draw_schedule_pdf
    return unless authorize_action!('finance', 'read')

    unless @invoice.draw_schedule.present? && @invoice.draw_schedule['draws'].present?
      return render json: { error: 'No draw schedule on this invoice' }, status: :unprocessable_entity
    end

    pdf_content = generate_draw_schedule_pdf(@invoice)

    send_data pdf_content,
      filename: "DrawSchedule-#{@invoice.invoice_number}.pdf",
      type: 'application/pdf',
      disposition: 'attachment'
  end
  
  def send_invoice
    return unless authorize_action!('finance', 'update')
    
    # Get send preferences from params (default to email only for backwards compatibility)
    send_email = params[:send_email].nil? ? true : ActiveModel::Type::Boolean.new.cast(params[:send_email])
    send_sms = params[:send_sms].nil? ? false : ActiveModel::Type::Boolean.new.cast(params[:send_sms])
    
    sent_methods = []
    errors = []
    
    # Send email if requested
    if send_email
      begin
        InvoiceMailer.invoice_email(@invoice).deliver_later
        sent_methods << 'email'
        Rails.logger.info "[InvoicesController#send_invoice] Email queued for invoice #{@invoice.id}"
      rescue => e
        errors << "email: #{e.message}"
        Rails.logger.error "[InvoicesController#send_invoice] Email failed: #{e.message}"
      end
    end
    
    # Send SMS if requested
    if send_sms
      begin
        # Initialize SMS service with location/company for three-tier inheritance
        sms_service = SmsService.new(
          location: @invoice.location,
          company: @invoice.company
        )
        
        # Send SMS notification
        result = sms_service.send_invoice_notification(@invoice)
        
        if result[:success]
          sent_methods << 'SMS'
          Rails.logger.info "[InvoicesController#send_invoice] SMS sent - SID: #{result[:message_sid]}"
        else
          errors << "SMS: #{result[:error]}"
          Rails.logger.error "[InvoicesController#send_invoice] SMS failed: #{result[:error]}"
        end
      rescue => e
        errors << "SMS: #{e.message}"
        Rails.logger.error "[InvoicesController#send_invoice] SMS exception: #{e.message}"
      end
    end
    
    # Only mark as sent if currently draft and at least one method succeeded
    if sent_methods.any? && (@invoice.draft? || @invoice.finalized?)
      @invoice.mark_as_sent!
    end
    
    # Build response message
    if sent_methods.any?
      message = "Invoice sent successfully via #{sent_methods.join(' and ')}"
      message += ". Errors: #{errors.join(', ')}" if errors.any?
      render json: { message: message, invoice: serialize_invoice(@invoice.reload) }
    elsif errors.any?
      render json: { error: "Failed to send invoice: #{errors.join(', ')}" }, status: :unprocessable_entity
    else
      render json: { error: 'No delivery method selected' }, status: :unprocessable_entity
    end
  end
  
  def send_sms
    return unless authorize_action!('finance', 'update')
    
    # Initialize SMS service with location/company for three-tier inheritance
    sms_service = SmsService.new(
      location: @invoice.location,
      company: @invoice.company
    )
    
    # Send SMS notification
    result = sms_service.send_invoice_notification(@invoice)
    
    if result[:success]
      Rails.logger.info "[InvoicesController#send_sms] SMS sent - SID: #{result[:message_sid]}"
      render json: { 
        message: 'SMS notification sent successfully', 
        invoice: @invoice,
        message_sid: result[:message_sid]
      }
    else
      Rails.logger.error "[InvoicesController#send_sms] SMS failed: #{result[:error]}"
      render json: { 
        error: result[:error] || 'Failed to send SMS notification' 
      }, status: :unprocessable_entity
    end
  end
  
  def mark_paid
    return unless authorize_action!('finance', 'update')
    
    amount = params[:amount]&.to_f || @invoice.amount_due
    
    if @invoice.record_payment!(amount, 'manual', { notes: params[:notes] })
      render json: { message: 'Payment recorded', invoice: @invoice.reload }
    else
      render json: { error: 'Failed to record payment' }, status: :unprocessable_entity
    end
  end
  
  def cancel
    return unless authorize_action!('finance', 'delete')
    
    if @invoice.update(status: 'cancelled')
      render json: @invoice
    else
      render json: { errors: @invoice.errors }, status: :unprocessable_entity
    end
  end

  def finalize
    return unless authorize_action!('finance', 'update')
    
    unless @invoice.draft?
      return render json: { error: 'Only draft invoices can be finalized' }, status: :unprocessable_entity
    end
    
    if @invoice.finalize!
      render json: { message: 'Invoice finalized', invoice: serialize_invoice(@invoice.reload) }
    else
      render json: { errors: @invoice.errors }, status: :unprocessable_entity
    end
  end
  
  def stats
    return unless authorize_action!('finance', 'read')
    
    base_invoices = @company.invoices.not_deleted
    
    # Apply account filter if provided - filter through contacts
    if params[:account_id].present?
      account_contact_ids = @company.contacts.where(account_id: params[:account_id]).pluck(:id)
      base_invoices = base_invoices.where(contact_id: account_contact_ids)
    end
    
    # Apply location selector filter
    base_invoices = base_invoices.where(location_id: Current.location_id) if Current.location_filtered?
    
    # CRITICAL: Exclude future loan invoices from stats (don't count draft loan payments not yet due)
    # This prevents inflated outstanding amounts from future loan payment schedules
    base_invoices = base_invoices.where(
      "(invoices.loan_id IS NULL) OR "\
      "(invoices.loan_id IS NOT NULL AND (invoices.status != 'draft' OR invoices.due_date <= ?))",
      Date.current
    )
    
    # Total count
    total_count = base_invoices.count
    
    # Unpaid count (draft, sent, viewed, partial, overdue - NOT paid or cancelled)
    unpaid_count = base_invoices.where.not(status: ['paid', 'cancelled']).count
    
    # Overdue count (status='overdue' OR past due date and not paid/cancelled)
    overdue_count = base_invoices.where(
      "status = 'overdue' OR (due_date < ? AND status NOT IN (?))", 
      Date.current, 
      ['paid', 'cancelled']
    ).count
    
    # Total outstanding (sum of amount_due for all unpaid invoices)
    total_outstanding = base_invoices
      .where.not(status: ['paid', 'cancelled'])
      .sum(:amount_due)
    
    # Paid this month (invoices with status='paid' and paid_at in current month)
    start_of_month = Date.current.beginning_of_month.beginning_of_day
    end_of_month = Date.current.end_of_month.end_of_day
    paid_this_month = base_invoices
      .where(status: 'paid')
      .where(paid_at: start_of_month..end_of_month)
      .sum(:total)
    
    # Payment success rate (completed payments / total payments this month)
    month_payments = Payment
      .where(company_id: @company.id)
      .where(payable_type: 'Invoice')
      .where(created_at: start_of_month..end_of_month)
    
    if Current.location_filtered?
      month_payments = month_payments.where(location_id: Current.location_id)
    end
    
    total_payments = month_payments.count
    successful_payments = month_payments.where(status: 'completed').count
    success_rate = total_payments > 0 ? (successful_payments.to_f / total_payments * 100).round(1) : 0
    
    render json: {
      total_count: total_count,
      unpaid_count: unpaid_count,
      overdue_count: overdue_count,
      total_outstanding: total_outstanding.to_f,
      paid_this_month: paid_this_month.to_f,
      payment_success_rate: success_rate,
      successful_payments_count: successful_payments
    }
  end
  
  # Convert a quote to an invoice
  def convert_from_quote
    return unless authorize_action!('finance', 'create')
    
    quote = @company.quotes.find(params[:quote_id])
    
    # Check if quote already converted
    if quote.invoices.any?
      return render json: { 
        error: 'Quote already converted to invoice',
        existing_invoice_id: quote.invoices.first.id
      }, status: :unprocessable_entity
    end
    
    # Create invoice from quote
    invoice = @company.invoices.build(
      quote_id: quote.id,
      contact_id: quote.contact_id,
      location_id: quote.location_id || Current.location_id,
      sales_rep_id: params[:sales_rep_id] || current_user.id, # Default to current user
      invoice_date: Date.current,
      due_date: Date.current + 30.days, # Default 30 days
      tax_rate: quote.tax || @company.settings.dig('quotes', 'defaultTaxRate') || 0,
      notes: quote.notes,
      terms: params[:terms] || @company.settings.dig('quotes', 'defaultTermsConditions')
    )
    
    # Copy line items from quote
    quote.items.each do |quote_item|
      invoice.invoice_items.build(
        description: quote_item[:description] || quote_item['description'],
        quantity: quote_item[:quantity] || quote_item['quantity'] || 1,
        rate: quote_item[:unitPrice] || quote_item['unitPrice'] || quote_item[:unit_price] || 0,
        item_type: quote_item[:itemType] || quote_item['itemType'] || 'custom',
        itemable_type: quote_item[:itemable_type] || quote_item['itemable_type'],
        itemable_id: quote_item[:itemable_id] || quote_item['itemable_id'],
        commission_type: 'full_commission' # Default
      )
    end
    
    if invoice.save
      render json: serialize_invoice(invoice), status: :created
    else
      render json: { errors: invoice.errors }, status: :unprocessable_entity
    end
  end
  
  # Manual override to mark inventory as used
  def mark_inventory_used
    return unless authorize_action!('finance', 'update')
    
    invoice = @company.invoices.find(params[:id])
    
    begin
      invoice.force_mark_inventory_as_used!(current_user)
      render json: { 
        message: 'Inventory marked as used', 
        invoice: serialize_invoice(invoice.reload) 
      }
    rescue => e
      render json: { 
        error: "Failed to mark inventory as used: #{e.message}" 
      }, status: :unprocessable_entity
    end
  end
  
  private
  
  def set_invoice
    @invoice = @company.invoices.includes(:invoice_items, :payments).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Invoice not found' }, status: :not_found
  end
  
  def invoice_params
    params.require(:invoice).permit(
      :contact_id, :location_id, :listing_id, :deal_id, :quote_id, :sales_rep_id,
      :invoice_date, :due_date, :tax_rate,
      :notes, :terms, :footer_text,
      # Addresses (billing + delivery)
      :billing_street, :billing_city, :billing_state, :billing_zip, :billing_country,
      :delivery_street, :delivery_city, :delivery_state, :delivery_zip, :delivery_country,
      # Custom fields
      custom_field_values: {},
      draw_schedule: {},
      invoice_items_attributes: [
        :id, :item_type, :description, :quantity, :rate, :amount, :listing_id, :position,
        :itemable_type, :itemable_id, :commission_type,
        :category, :cost, :taxable, :tax_rate, :notes,
        :_destroy
      ]
    )
  end
  
  def serialize_invoice(invoice)
    Rails.logger.info "🔍 [serialize_invoice] Starting serialization for invoice #{invoice.id}"
    
    # Include recipient details based on type
    recipient_data = begin
      if invoice.recipient_type == 'Manufacturer' && invoice.recipient_id.present?
        Rails.logger.info "🔍 [serialize_invoice] Loading manufacturer #{invoice.recipient_id}"
        manufacturer = Manufacturer.find_by(id: invoice.recipient_id)
        manufacturer ? {
          id: manufacturer.id,
          name: manufacturer.name,
          type: 'Manufacturer'
        } : nil
      elsif invoice.recipient_type == 'Contact' && invoice.contact_id.present?
        Rails.logger.info "🔍 [serialize_invoice] Loading contact via recipient_type #{invoice.contact_id}"
        contact = Contact.find_by(id: invoice.contact_id)
        contact ? {
          id: contact.id,
          first_name: contact.first_name,
          last_name: contact.last_name,
          email: contact.email,
          phone: contact.phone,
          type: 'Contact'
        } : nil
      elsif invoice.contact_id.present?
        Rails.logger.info "🔍 [serialize_invoice] Loading contact (standard invoice) #{invoice.contact_id}"
        contact = Contact.find_by(id: invoice.contact_id)
        contact ? {
          id: contact.id,
          first_name: contact.first_name,
          last_name: contact.last_name,
          email: contact.email,
          phone: contact.phone,
          type: 'Contact'
        } : nil
      else
        Rails.logger.info "🔍 [serialize_invoice] No recipient or contact found"
        nil
      end
    rescue => e
      Rails.logger.error "❌ [serialize_invoice] Error loading recipient: #{e.message}"
      nil
    end
    
    Rails.logger.info "🔍 [serialize_invoice] Recipient data: #{recipient_data.inspect}"
    
    result = {
      id: invoice.id,
      invoice_number: invoice.invoice_number,
      invoice_date: invoice.invoice_date,
      due_date: invoice.due_date,
      paid_at: invoice.paid_at,
      sent_at: invoice.sent_at,
      viewed_at: invoice.viewed_at,
      status: invoice.status,
      billing_category: invoice.billing_category,
      payment_token: invoice.payment_token,
      subtotal: invoice.subtotal,
      tax_rate: invoice.tax_rate,
      tax_amount: invoice.tax_amount,
      total: invoice.total,
      amount_due: invoice.amount_due,
      amount_paid: invoice.amount_paid,
      notes: invoice.notes,
      terms: invoice.terms,
      footer_text: invoice.footer_text,
      source_type: invoice.source_type,
      source_id: invoice.source_id,
      recipient_type: invoice.recipient_type,
      recipient_id: invoice.recipient_id,
      recipient: recipient_data,
      contact: recipient_data&.dig(:type) == 'Contact' ? recipient_data : nil,
      contact_id: invoice.contact_id,
      location_id: invoice.location_id,
      sales_rep_id: invoice.sales_rep_id,  # CRITICAL: Include sales_rep_id so it persists on edit
      deal_id: invoice.deal_id,
      deal: invoice.deal_id.present? ? serialize_deal_reference(invoice) : nil,
      quote_id: invoice.quote_id,
      draw_schedule: invoice.draw_schedule,
      invoice_items: begin
        (invoice.invoice_items || []).map { |item| serialize_invoice_item(item) }
      rescue => e
        Rails.logger.error "❌ [serialize_invoice] Error serializing items: #{e.message}"
        []
      end,
      payments: begin
        invoice.payments.to_a.map { |payment| serialize_payment(payment) }
      rescue => e
        Rails.logger.error "❌ [serialize_invoice] Error serializing payments: #{e.message}"
        []
      end,
      payments_enabled: invoice.company.external_payments_id.present?,
      created_at: invoice.created_at,
      updated_at: invoice.updated_at
    }
    
    Rails.logger.info "✅ [serialize_invoice] Completed serialization for invoice #{invoice.id}"
    result
  rescue => e
    Rails.logger.error "❌ [serialize_invoice] Fatal error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end
  
  def serialize_deal_reference(invoice)
    deal = invoice.deal
    return nil unless deal
    {
      id: deal.id,
      deal_number: deal.deal_number,
      name: deal.name,
      stage: deal.stage,
      value: deal.value,
      customer_name: deal.customer_name,
      contact_id: deal.contact_id,
      vehicle_id: deal.vehicle_id
    }
  rescue => e
    Rails.logger.error "[serialize_deal_reference] Error: #{e.message}"
    nil
  end

  def serialize_invoice_item(item)
    {
      id: item.id,
      item_type: item.item_type,
      description: item.description,
      quantity: item.quantity,
      rate: item.rate,
      amount: item.amount,
      position: item.position,
      itemable_type: item.itemable_type,
      itemable_id: item.itemable_id,
      commission_type: item.commission_type,
      category: item.category,
      cost: item.cost,
      taxable: item.taxable,
      tax_rate: item.tax_rate,
      tax_amount: item.tax_amount,
      notes: item.notes
    }
  end
  
  def serialize_payment(payment)
    {
      id: payment.id,
      amount: payment.amount,
      payment_method: payment.payment_method,
      status: payment.status,
      payment_date: payment.payment_date,
      created_at: payment.created_at
    }
  end
  
  def serialize_invoice_list_item(invoice)
    # Lightweight serialization for list view
    recipient_data = if invoice.recipient_type == 'Manufacturer' && invoice.recipient_id.present?
      manufacturer = Manufacturer.find_by(id: invoice.recipient_id)
      manufacturer ? {
        id: manufacturer.id,
        name: manufacturer.name,
        type: 'Manufacturer'
      } : nil
    elsif invoice.contact.present?
      {
        id: invoice.contact.id,
        first_name: invoice.contact.first_name,
        last_name: invoice.contact.last_name,
        full_name: "#{invoice.contact.first_name} #{invoice.contact.last_name}",
        email: invoice.contact.email,
        type: 'Contact'
      }
    else
      nil
    end
    
    {
      id: invoice.id,
      invoice_number: invoice.invoice_number,
      invoice_date: invoice.invoice_date,
      due_date: invoice.due_date,
      paid_at: invoice.paid_at,
      status: invoice.status,
      billing_category: invoice.billing_category,
      total: invoice.total,
      amount_due: invoice.amount_due,
      amount_paid: invoice.amount_paid,
      recipient_type: invoice.recipient_type,
      recipient: recipient_data,
      contact: recipient_data&.dig(:type) == 'Contact' ? recipient_data : nil,
      draw_schedule: invoice.draw_schedule,
      deal_id: invoice.deal_id,
      deal: invoice.deal_id.present? ? serialize_deal_reference(invoice) : nil,
      created_at: invoice.created_at,
      updated_at: invoice.updated_at
    }
  end

  # Resolve branding for invoice: logo, address, colors based on company setting
  def resolve_invoice_branding(invoice)
    company = invoice.company
    location = invoice.location
    loan_settings = company.loan_settings || {}
    source_pref = loan_settings['invoice_branding_source'] || 'location'
    
    # Resolve branding settings (location → company fallback)
    branding = {}
    if source_pref == 'location' && location.present?
      loc_branding = Setting.get('Location', location.id, 'branding') rescue {} || {}
      branding = loc_branding if loc_branding.present? && loc_branding.any?
    end
    
    # Fallback to company branding
    if branding.blank?
      branding = Setting.get('Company', company.id, 'branding') rescue {} || {}
    end
    
    # Resolve logo URL - convert relative paths to absolute
    raw_logo = branding['logo'].presence
    if raw_logo.present? && !raw_logo.start_with?('http://', 'https://')
      api_base = ENV['RAILS_API_URL'] || ENV['API_URL'] || 'https://localhost:3001'
      logo_url = "#{api_base}#{raw_logo}"
    else
      logo_url = raw_logo
    end
    
    # Resolve address based on preference
    if source_pref == 'company'
      # Use company's own contact info (new fields), fallback to location
      address = {
        name: company.name,
        phone: company.phone.presence || location&.phone,
        email: company.email.presence || location&.email,
        line1: company.address_line1.presence || location&.address_line1,
        city: company.city.presence || location&.city,
        state: company.state.presence || location&.state,
        zip: company.zip_code.presence || location&.zip_code
      }
    else
      # Use location info, fallback to company
      address = {
        name: location&.name || company.name,
        phone: location&.phone.presence || company.phone,
        email: location&.email.presence || company.email,
        line1: location&.address_line1.presence || company.address_line1,
        city: location&.city.presence || company.city,
        state: location&.state.presence || company.state,
        zip: location&.zip_code.presence || company.zip_code
      }
    end
    
    # Resolve accent color (strip # for Prawn)
    primary_color = (branding['primaryColor'] || branding['primary_color'] || '#2563EB').to_s.delete('#')
    
    { logo_url: logo_url, address: address, accent: primary_color, company_name: company.name }
  end

  # Load image data - tries local disk first (for /uploads/ paths), then HTTP
  def load_image_data(url)
    # Check if it's a local upload path - read from disk directly
    # This avoids HTTP self-request which can deadlock in dev
    if url.present? && url.include?('/uploads/')
      relative_path = url.sub(%r{^https?://[^/]+}, '') # Strip host if present
      upload_base = ENV['UPLOAD_PATH'] || Rails.root.join('public', 'uploads')
      # relative_path is like /uploads/19/logos/company/uuid.png
      local_path = File.join(upload_base.to_s.sub(/\/uploads$/, ''), relative_path.sub(/^\//, ''))
      
      # Also try just the uploads subdirectory
      alt_path = File.join(upload_base.to_s, relative_path.sub(%r{^/uploads/}, ''))
      
      if File.exist?(local_path)
        Rails.logger.info "[Invoice PDF] Loading logo from disk: #{local_path}"
        return File.binread(local_path)
      elsif File.exist?(alt_path)
        Rails.logger.info "[Invoice PDF] Loading logo from disk (alt): #{alt_path}"
        return File.binread(alt_path)
      else
        Rails.logger.warn "[Invoice PDF] Local file not found: #{local_path} or #{alt_path}"
      end
    end
    
    # Fall back to HTTP download (for S3 URLs, external URLs)
    return nil unless url.present? && url.start_with?('http://', 'https://')
    download_image_http(url)
  end

  # Download image via HTTP with redirect following (for S3 signed URLs)
  def download_image_http(url, max_redirects: 3)
    uri = URI.parse(url)
    redirects = 0
    
    loop do
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE if !Rails.env.production?
      http.open_timeout = 5
      http.read_timeout = 10
      
      request = Net::HTTP::Get.new(uri.request_uri)
      response = http.request(request)
      
      case response
      when Net::HTTPSuccess
        return response.body
      when Net::HTTPRedirection
        redirects += 1
        raise "Too many redirects" if redirects > max_redirects
        uri = URI.parse(response['location'])
      else
        raise "HTTP #{response.code}: #{response.message}"
      end
    end
  end

  def generate_invoice_pdf(invoice)
    require 'prawn'
    require 'prawn/table'
    
    h = ActionController::Base.helpers
    company = invoice.company
    contact = invoice.contact
    brand = resolve_invoice_branding(invoice)
    accent = brand[:accent]
    addr = brand[:address]
    
    Prawn::Document.new(page_size: 'LETTER', margin: [50, 50, 60, 50]) do |pdf|
      
      # ── HEADER: Logo (left) + Address (right) ──
      header_top = pdf.cursor
      
      # Try to load logo
      logo_loaded = false
      if brand[:logo_url].present?
        begin
          logo_data = load_image_data(brand[:logo_url])
          if logo_data.present?
            pdf.image StringIO.new(logo_data), fit: [150, 60], position: :left
            logo_loaded = true
          end
        rescue => e
          Rails.logger.warn "[Invoice PDF] Failed to load logo from #{brand[:logo_url]}: #{e.message}"
        end
      end
      
      unless logo_loaded
        pdf.text brand[:company_name], size: 18, style: :bold
      end
      
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
      
      # Accent line
      pdf.stroke_color accent
      pdf.line_width = 1.5
      pdf.stroke_horizontal_rule
      pdf.stroke_color '000000'
      pdf.move_down 20
      
      # ── METADATA GRID: Billed To | Date | Invoice # | Amount Due ──
      meta_top = pdf.cursor
      col_w = (pdf.bounds.width / 4.0).floor
      
      # Billed To
      pdf.bounding_box([0, meta_top], width: col_w * 1.3) do
        pdf.text 'Billed To', size: 8, color: accent
        if contact
          pdf.text "#{contact.first_name} #{contact.last_name}", size: 10, style: :bold
          pdf.text contact.street, size: 9 if contact.street.present?
          city_line = [contact.city, contact.state, contact.zip].compact.join(', ')
          pdf.text city_line, size: 9 if city_line.present?
        elsif invoice.recipient_type == 'Manufacturer'
          manufacturer = Manufacturer.find_by(id: invoice.recipient_id)
          pdf.text manufacturer&.name || 'Manufacturer', size: 10, style: :bold
        end
      end
      
      # Date of Issue
      pdf.bounding_box([col_w * 1.3, meta_top], width: col_w * 0.7) do
        pdf.text 'Date of Issue', size: 8, color: accent
        pdf.text invoice.invoice_date.strftime('%m/%d/%Y'), size: 10
        pdf.move_down 6
        pdf.text 'Due Date', size: 8, color: accent
        pdf.text(invoice.due_date&.strftime('%m/%d/%Y') || 'N/A', size: 10)
      end
      
      # Invoice Number
      pdf.bounding_box([col_w * 2, meta_top], width: col_w * 0.8) do
        pdf.text 'Invoice Number', size: 8, color: accent
        pdf.text invoice.invoice_number, size: 10
      end
      
      # Amount Due
      pdf.bounding_box([col_w * 2.8, meta_top], width: col_w * 1.2) do
        pdf.text 'Amount Due (USD)', size: 8, color: accent
        pdf.text h.number_to_currency(invoice.amount_due), size: 20, style: :bold
      end
      
      pdf.move_cursor_to meta_top - 60
      pdf.move_down 15
      
      # ── LINE ITEMS TABLE ──
      has_per_item_tax = invoice.invoice_items.any?(&:taxable?)
      
      items_data = []
      items_data << ['Description', 'Rate', 'Qty', 'Line Total']
      
      invoice.invoice_items.order(:position, :id).each do |item|
        # Build description with optional notes and tax indicator
        desc_parts = []
        desc_parts << item.description
        desc_parts << item.notes if item.notes.present?
        desc_text = desc_parts.join("\n")
        
        rate_text = h.number_to_currency(item.rate)
        rate_text += "\n+Sales Tax" if item.taxable?
        
        items_data << [
          desc_text,
          rate_text,
          item.quantity.to_i == item.quantity ? item.quantity.to_i.to_s : item.quantity.to_s,
          h.number_to_currency(item.amount)
        ]
      end
      
      desc_col_w = pdf.bounds.width - 250
      
      pdf.table(items_data, header: true, width: pdf.bounds.width,
                column_widths: { 0 => desc_col_w, 1 => 90, 2 => 50, 3 => 110 },
                cell_style: { padding: [8, 6], size: 9, border_width: 0, border_color: 'DDDDDD' }) do |t|
        # Header row
        t.row(0).font_style = :bold
        t.row(0).size = 9
        t.row(0).text_color = accent
        t.row(0).border_bottom_width = 1
        t.row(0).border_bottom_color = accent
        
        # Data rows - bottom border only
        (1..t.row_length - 1).each do |i|
          t.row(i).border_bottom_width = 0.5
          t.row(i).border_bottom_color = 'EEEEEE'
        end
        
        # Right-align numeric columns
        t.columns(1..3).align = :right
      end
      
      pdf.move_down 15
      
      # ── TOTALS ──
      totals_x = pdf.bounds.right - 240
      
      pdf.bounding_box([totals_x, pdf.cursor], width: 240) do
        totals = []
        totals << ['Subtotal', h.number_to_currency(invoice.subtotal)]
        
        if has_per_item_tax
          taxable_sub = invoice.invoice_items.select(&:taxable?).sum(&:amount)
          totals << ["Sales Tax (#{invoice.tax_rate}%)", h.number_to_currency(invoice.tax_amount)]
          totals << ['#Sales Tax', h.number_to_currency(taxable_sub)] if taxable_sub != invoice.subtotal
        else
          totals << ["Tax (#{invoice.tax_rate}%)", h.number_to_currency(invoice.tax_amount)]
        end
        
        pdf.table(totals, cell_style: { borders: [], padding: [4, 6], size: 9 },
                  column_widths: [140, 100]) do |t|
          t.columns(0).align = :right
          t.columns(1).align = :right
        end
        
        # Total line (with top border)
        pdf.table(
          [['Total', h.number_to_currency(invoice.total)]],
          cell_style: { borders: [:top], border_color: accent, padding: [6, 6], size: 11 },
          column_widths: [140, 100]
        ) do |t|
          t.columns(0).align = :right
          t.columns(0).font_style = :bold
          t.columns(1).align = :right
          t.columns(1).font_style = :bold
        end
        
        # Amount Paid + Amount Due (if applicable)
        if invoice.amount_paid.to_f > 0
          paid_due = [
            ['Amount Paid', h.number_to_currency(invoice.amount_paid)],
          ]
          pdf.table(paid_due, cell_style: { borders: [], padding: [4, 6], size: 9 },
                    column_widths: [140, 100]) do |t|
            t.columns(0..1).align = :right
          end
          
          # Amount Due with accent
          pdf.table(
            [['Amount Due (USD)', h.number_to_currency(invoice.amount_due)]],
            cell_style: { borders: [:top], border_color: accent, padding: [6, 6], size: 12 },
            column_widths: [140, 100]
          ) do |t|
            t.columns(0).align = :right
            t.columns(0).text_color = accent
            t.columns(0).font_style = :bold
            t.columns(1).align = :right
            t.columns(1).font_style = :bold
          end
        end
      end
      
      # ── DRAW SCHEDULE (if included on invoice) ──
      if invoice.draw_schedule.present? && invoice.draw_schedule['draws'].present? && invoice.draw_schedule['include_on_invoice'] != false
        pdf.move_down 25
        pdf.text 'Payment Draw Schedule', size: 11, style: :bold
        pdf.move_down 5
        
        schedule = invoice.draw_schedule
        draw_data = schedule['draws'].sort_by { |d| d['position'] || 0 }.map do |draw|
          ["#{draw['percentage']}%", draw['description'], h.number_to_currency(draw['amount'])]
        end
        
        pdf.table(draw_data, cell_style: { borders: [], padding: [4, 6], size: 9 },
                  column_widths: [50, pdf.bounds.width - 160, 110]) do |t|
          t.columns(0).font_style = :bold
          t.columns(2).align = :right
        end
      end
      
      # ── NOTES ──
      if invoice.notes.present?
        pdf.move_down 25
        pdf.text 'Notes', size: 10, style: :bold, color: accent
        pdf.move_down 3
        pdf.text invoice.notes, size: 9
      end
      
      # ── TERMS ──
      if invoice.terms.present?
        pdf.move_down 15
        pdf.text 'Terms', size: 10, style: :bold, color: accent
        pdf.move_down 3
        pdf.text invoice.terms, size: 9
      end
      
      # ── FOOTER ──
      if invoice.footer_text.present?
        pdf.move_down 20
        pdf.text invoice.footer_text, size: 8, align: :center, color: '999999'
      end
      
      # Page numbers
      pdf.number_pages 'Page <page> of <total>', at: [pdf.bounds.right - 150, 0], align: :right, size: 8, color: '999999'
    end.render
  end

  def generate_draw_schedule_pdf(invoice)
    require 'prawn'
    require 'prawn/table'

    h = ActionController::Base.helpers
    brand = resolve_invoice_branding(invoice)
    accent = brand[:accent]
    addr = brand[:address]
    contact = invoice.contact
    schedule = invoice.draw_schedule
    draws = (schedule['draws'] || []).sort_by { |d| d['position'] || 0 }

    Prawn::Document.new(page_size: 'LETTER', margin: [50, 50, 60, 50]) do |pdf|

      # ── HEADER ──
      header_top = pdf.cursor
      logo_loaded = false
      if brand[:logo_url].present?
        begin
          logo_data = load_image_data(brand[:logo_url])
          pdf.image StringIO.new(logo_data), fit: [150, 60], position: :left
          logo_loaded = true
        rescue => e
          Rails.logger.warn "[Draw Schedule PDF] Failed to load logo: #{e.message}"
        end
      end
      pdf.text brand[:company_name], size: 18, style: :bold unless logo_loaded
      logo_bottom = pdf.cursor

      pdf.bounding_box([pdf.bounds.right - 200, header_top], width: 200) do
        pdf.text addr[:name], size: 11, style: :bold, align: :right
        pdf.text addr[:phone], size: 9, align: :right if addr[:phone].present?
        pdf.text addr[:line1], size: 9, align: :right if addr[:line1].present?
        city_state = [addr[:city], addr[:state], addr[:zip]].compact.join(', ')
        pdf.text city_state, size: 9, align: :right if city_state.present?
      end

      pdf.move_cursor_to [logo_bottom, pdf.cursor].min - 5
      pdf.stroke_color accent
      pdf.line_width = 1.5
      pdf.stroke_horizontal_rule
      pdf.stroke_color '000000'
      pdf.move_down 25

      # ── TITLE ──
      pdf.text 'Loan Disbursement Schedule', size: 20, style: :bold, color: accent
      pdf.move_down 5
      pdf.text schedule['template_name'] || 'Payment Draw Schedule', size: 11, color: '666666'
      pdf.move_down 20

      # ── REFERENCE INFO ──
      col_w = (pdf.bounds.width / 3.0).floor
      meta_top = pdf.cursor

      pdf.bounding_box([0, meta_top], width: col_w) do
        pdf.text 'Invoice', size: 8, color: accent
        pdf.text invoice.invoice_number, size: 11, style: :bold
        pdf.move_down 8
        pdf.text 'Date', size: 8, color: accent
        pdf.text invoice.invoice_date.strftime('%m/%d/%Y'), size: 10
      end

      pdf.bounding_box([col_w, meta_top], width: col_w) do
        pdf.text 'Buyer', size: 8, color: accent
        if contact
          pdf.text "#{contact.first_name} #{contact.last_name}", size: 11, style: :bold
          pdf.text contact.street, size: 9 if contact.respond_to?(:street) && contact.street.present?
          city_line = [contact.city, contact.state, contact.zip].compact.join(', ')
          pdf.text city_line, size: 9 if city_line.present?
        end
      end

      pdf.bounding_box([col_w * 2, meta_top], width: col_w) do
        pdf.text 'Total Amount', size: 8, color: accent
        pdf.text h.number_to_currency(invoice.total), size: 18, style: :bold
      end

      pdf.move_cursor_to meta_top - 70
      pdf.move_down 20

      # ── DRAW TABLE ──
      table_data = [['Draw #', 'Description', '%', 'Amount']]

      draws.each_with_index do |draw, i|
        table_data << [
          "Draw #{i + 1}",
          draw['description'] || '',
          "#{draw['percentage']}%",
          h.number_to_currency(draw['amount'])
        ]
      end

      # Total row
      total_pct = draws.sum { |d| d['percentage'].to_f }
      total_amt = draws.sum { |d| d['amount'].to_f }
      table_data << ['', 'Total', "#{total_pct.round(1)}%", h.number_to_currency(total_amt)]

      pdf.table(table_data, header: true, width: pdf.bounds.width,
                column_widths: { 0 => 70, 2 => 55, 3 => 110 },
                cell_style: { padding: [10, 8], size: 10, border_width: 0.5, border_color: 'DDDDDD' }) do |t|
        t.row(0).font_style = :bold
        t.row(0).text_color = 'FFFFFF'
        t.row(0).background_color = accent
        t.row(0).border_color = accent

        # Last row (total) - bold with top border
        t.row(-1).font_style = :bold
        t.row(-1).border_top_width = 2
        t.row(-1).border_top_color = accent

        t.columns(2..3).align = :right
      end

      pdf.number_pages 'Page <page> of <total>', at: [pdf.bounds.right - 150, 0], align: :right, size: 8, color: '999999'
    end.render
  end
end
