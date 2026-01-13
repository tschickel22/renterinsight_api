class Api::V1::InvoicesController < ApplicationController
  before_action :set_company_scope
  before_action :set_invoice, only: [:show, :update, :destroy, :send_invoice, :send_sms, :mark_paid, :cancel, :pdf]
  
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
    invoices = invoices.where(status: params[:status]) if params[:status].present?
    invoices = invoices.where(contact_id: params[:contact_id]) if params[:contact_id].present?
    
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
    
    invoices = invoices.includes(:contact, :location, :invoice_items)
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
    
    invoice = @company.invoices.build(invoice_params)
    invoice.location_id ||= Current.location_id if Current.location_id.present?
    
    # RBAC fallback
    if invoice.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
      location_ids = permission_service.accessible_location_ids
      invoice.location_id = location_ids.first if location_ids.any?
    end
    
    if invoice.save
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
    if sent_methods.any? && @invoice.draft?
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
  
  private
  
  def set_invoice
    @invoice = @company.invoices.includes(:invoice_items, :payments).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Invoice not found' }, status: :not_found
  end
  
  def invoice_params
    params.require(:invoice).permit(
      :contact_id, :location_id, :listing_id, :deal_id,
      :invoice_date, :due_date, :tax_rate,
      :notes, :terms, :footer_text,
      invoice_items_attributes: [
        :id, :item_type, :description, :quantity, :rate, :amount, :listing_id, :position, :_destroy
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
  
  def serialize_invoice_item(item)
    {
      id: item.id,
      item_type: item.item_type,
      description: item.description,
      quantity: item.quantity,
      rate: item.rate,
      amount: item.amount,  # Fixed: InvoiceItem uses 'amount' not 'total'
      position: item.position
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
      created_at: invoice.created_at,
      updated_at: invoice.updated_at
    }
  end

  def generate_invoice_pdf(invoice)
    require 'prawn'
    require 'prawn/table'
    
    Prawn::Document.new(page_size: 'LETTER', margin: 50) do |pdf|
      # Company/Location Header
      company = invoice.company
      location = invoice.location
      
      pdf.text company.name, size: 20, style: :bold
      if location
        pdf.text location.name, size: 12
        pdf.text "#{location.address_line1}, #{location.city}, #{location.state} #{location.zip_code}", size: 10 if location.address_line1
        pdf.text "Phone: #{location.phone}", size: 10 if location.phone
        pdf.text "Email: #{location.email}", size: 10 if location.email
      end
      
      pdf.move_down 30
      
      # Invoice Title
      pdf.text "INVOICE ##{invoice.invoice_number}", size: 24, style: :bold, align: :center
      pdf.move_down 20
      
      # Invoice Details Grid
      details_data = [
        ['Invoice Date:', invoice.invoice_date.strftime('%m/%d/%Y'), 'Due Date:', invoice.due_date&.strftime('%m/%d/%Y') || 'N/A'],
        ['Status:', invoice.status.titleize, 'Amount Due:', ActionController::Base.helpers.number_to_currency(invoice.amount_due)]
      ]
      
      pdf.table(details_data, cell_style: { borders: [], padding: 5 }, column_widths: [100, 150, 100, 150]) do
        cells.style do |c|
          c.font_style = :bold if c.column.even?
        end
      end
      
      pdf.move_down 20
      
      # Bill To Section
      pdf.text 'Bill To:', size: 14, style: :bold
      pdf.move_down 5
      
      if invoice.contact
        pdf.text "#{invoice.contact.first_name} #{invoice.contact.last_name}", size: 12
        pdf.text invoice.contact.email, size: 10 if invoice.contact.email
        pdf.text invoice.contact.phone, size: 10 if invoice.contact.phone
        if invoice.contact.respond_to?(:address_line1) && invoice.contact.address_line1
          pdf.text "#{invoice.contact.address_line1}", size: 10
          pdf.text "#{invoice.contact.city}, #{invoice.contact.state} #{invoice.contact.zip_code}", size: 10 if invoice.contact.city
        end
      elsif invoice.recipient_type == 'Manufacturer'
        manufacturer = Manufacturer.find_by(id: invoice.recipient_id)
        if manufacturer
          pdf.text manufacturer.name, size: 12
        end
      end
      
      pdf.move_down 20
      
      # Line Items Table
      items_data = [['Description', 'Qty', 'Rate', 'Amount']]
      
      invoice.invoice_items.each do |item|
        items_data << [
          item.description,
          item.quantity.to_s,
          ActionController::Base.helpers.number_to_currency(item.rate),
          ActionController::Base.helpers.number_to_currency(item.amount)
        ]
      end
      
      pdf.table(items_data, header: true,
                cell_style: { padding: 8 }) do
        row(0).font_style = :bold
        row(0).background_color = 'EEEEEE'
        columns(1..3).align = :right
      end
      
      pdf.move_down 20
      
      # Totals Section
      totals_x = pdf.bounds.right - 250
      
      pdf.bounding_box([totals_x, pdf.cursor], width: 250) do
        totals_data = [
          ['Subtotal:', ActionController::Base.helpers.number_to_currency(invoice.subtotal)],
          ["Tax (#{invoice.tax_rate}%):", ActionController::Base.helpers.number_to_currency(invoice.tax_amount)],
          ['Total:', ActionController::Base.helpers.number_to_currency(invoice.total)]
        ]
        
        if invoice.amount_paid > 0
          totals_data << ['Amount Paid:', "(#{ActionController::Base.helpers.number_to_currency(invoice.amount_paid)})"]
          totals_data << ['Amount Due:', ActionController::Base.helpers.number_to_currency(invoice.amount_due)]
        end
        
        pdf.table(totals_data, cell_style: { borders: [], padding: 5 }, column_widths: [150, 100]) do
          columns(1).align = :right
          row(-1).font_style = :bold if invoice.amount_paid > 0
          row(-3).font_style = :bold unless invoice.amount_paid > 0
        end
      end
      
      pdf.move_down 30
      
      # Notes
      if invoice.notes.present?
        pdf.text 'Notes:', size: 12, style: :bold
        pdf.text invoice.notes, size: 10
        pdf.move_down 10
      end
      
      # Terms
      if invoice.terms.present?
        pdf.text 'Payment Terms:', size: 12, style: :bold
        pdf.text invoice.terms, size: 10
        pdf.move_down 10
      end
      
      # Footer
      if invoice.footer_text.present?
        pdf.move_down 20
        pdf.text invoice.footer_text, size: 9, align: :center, color: '666666'
      end
      
      # Page numbers
      pdf.number_pages 'Page <page> of <total>', at: [pdf.bounds.right - 150, 0], align: :right, size: 9
    end.render
  end
end
