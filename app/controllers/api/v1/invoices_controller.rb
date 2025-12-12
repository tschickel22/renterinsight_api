class Api::V1::InvoicesController < ApplicationController
  before_action :set_company_scope
  before_action :set_invoice, only: [:show, :update, :destroy, :send_invoice, :send_sms, :mark_paid, :cancel]
  
  def index
    return unless authorize_action!('invoices', 'read')
    
    invoices = @company.invoices.not_deleted
    
    # RBAC + Location Filtering
    if current_user.uses_rbac?
      unless current_user.effective_admin?
        location_ids = permission_service.accessible_location_ids
        invoices = location_ids.any? ? 
          invoices.where(location_id: location_ids) : 
          invoices.none
      end
    end
    
    # Apply location selector filter
    invoices = invoices.for_current_location
    
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
    return unless authorize_action!('invoices', 'read')
    
    render json: serialize_invoice(@invoice)
  end
  
  def create
    return unless authorize_action!('invoices', 'create')
    
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
    return unless authorize_action!('invoices', 'update')
    
    if @invoice.update(invoice_params)
      render json: @invoice, include: [:contact, :invoice_items]
    else
      render json: { errors: @invoice.errors }, status: :unprocessable_entity
    end
  end
  
  def destroy
    return unless authorize_action!('invoices', 'delete')
    
    @invoice.update(is_deleted: true)
    head :no_content
  end
  
  def send_invoice
    return unless authorize_action!('invoices', 'update')
    
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
    return unless authorize_action!('invoices', 'update')
    
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
    return unless authorize_action!('invoices', 'update')
    
    amount = params[:amount]&.to_f || @invoice.amount_due
    
    if @invoice.record_payment!(amount, 'manual', { notes: params[:notes] })
      render json: { message: 'Payment recorded', invoice: @invoice.reload }
    else
      render json: { error: 'Failed to record payment' }, status: :unprocessable_entity
    end
  end
  
  def cancel
    return unless authorize_action!('invoices', 'delete')
    
    if @invoice.update(status: 'cancelled')
      render json: @invoice
    else
      render json: { errors: @invoice.errors }, status: :unprocessable_entity
    end
  end
  
  def stats
    return unless authorize_action!('invoices', 'read')
    
    base_invoices = @company.invoices.not_deleted
    
    # Apply account filter if provided - filter through contacts
    if params[:account_id].present?
      account_contact_ids = @company.contacts.where(account_id: params[:account_id]).pluck(:id)
      base_invoices = base_invoices.where(contact_id: account_contact_ids)
    end
    
    # Apply location selector filter
    base_invoices = base_invoices.where(location_id: Current.location_id) if Current.location_filtered?
    
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
      total: item.total,
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
end
