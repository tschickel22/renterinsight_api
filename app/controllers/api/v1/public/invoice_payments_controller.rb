class Api::V1::Public::InvoicePaymentsController < ApplicationController
  skip_before_action :authenticate
  before_action :set_invoice
  
  def show
    # Mark as viewed if first time
    @invoice.mark_as_viewed! unless @invoice.viewed_at
    
    # Resolve branding based on company setting (location vs company)
    company = @invoice.company
    location = @invoice.location
    loan_settings = company.loan_settings || {}
    source_pref = loan_settings['invoice_branding_source'] || 'location'
    
    # Resolve branding settings with fallback
    brand_settings = {}
    if source_pref == 'location' && location.present?
      brand_settings = Setting.get('Location', location.id, 'branding') rescue {} || {}
    end
    brand_settings = Setting.get('Company', company.id, 'branding') rescue {} if brand_settings.blank?
    brand_settings ||= {}
    
    # Resolve address based on preference
    if source_pref == 'company'
      address_parts = [company.address_line1.presence || location&.address_line1,
                       company.city.presence || location&.city,
                       company.state.presence || location&.state,
                       company.zip_code.presence || location&.zip_code].compact
      display_name = company.name
      display_phone = company.phone.presence || location&.phone
      display_email = company.email.presence || location&.email
    else
      address_parts = location ? [location.address_line1, location.city, location.state, location.zip_code].compact : 
                                [company.address_line1, company.city, company.state, company.zip_code].compact
      display_name = location&.name || company.name
      display_phone = location&.phone.presence || company.phone
      display_email = location&.email.presence || company.email
    end
    
    # Resolve logo URL - convert relative paths to absolute
    raw_logo = brand_settings['logo']
    if raw_logo.present? && !raw_logo.start_with?('http://', 'https://')
      api_base = ENV['RAILS_API_URL'] || ENV['API_URL'] || 'https://localhost:3001'
      resolved_logo = "#{api_base}#{raw_logo}"
    else
      resolved_logo = raw_logo
    end
    
    branding = {
      company_name: display_name,
      company_logo: resolved_logo,
      company_address: address_parts.join(', '),
      company_phone: display_phone,
      company_email: display_email,
      location_name: location&.name,
      location_address: address_parts.join(', '),
      primary_color: brand_settings['primaryColor'] || brand_settings['primary_color']
    }
    
    render json: {
      invoice: @invoice.as_json(
        only: [:id, :invoice_number, :invoice_date, :due_date, :status,
               :subtotal, :tax_rate, :tax_amount, :total, :amount_paid, :amount_due,
               :notes, :terms, :draw_schedule]
      ).merge(
        'invoice_items' => @invoice.invoice_items.order(:position, :id).map { |item|
          item.as_json(only: [:id, :description, :quantity, :rate, :amount, :category, :taxable, :notes])
        }
      ),
      contact: @invoice.contact.as_json(only: [:id, :first_name, :last_name, :email, :phone, :street, :city, :state, :zip]),
      branding: branding,
      payment_url: @invoice.payment_url,
      payments_enabled: @invoice.company.external_payments_id.present?
    }
  end
  
  def process_payment
    unless @invoice.company.external_payments_id.present?
      return render json: { error: 'Online payments are not enabled for this account. Please contact the business directly.' }, status: :unprocessable_entity
    end

    payment_method_params = params.require(:payment_method).permit(
      :payment_type, :billing_first_name, :billing_last_name,
      :billing_street, :billing_city, :billing_state, :billing_zip,
      :credit_card_number, :credit_card_expires_on, :credit_card_cvv,
      :ach_routing_number, :ach_account_number, :ach_account_type,
      :is_debit_card
    )
    
    amount = params[:amount]&.to_f || @invoice.amount_due
    
    if amount <= 0 || amount > @invoice.amount_due
      return render json: { error: 'Invalid payment amount' }, status: :unprocessable_entity
    end
    
    # Map frontend params to model attributes
    method_params = payment_method_params.to_h.symbolize_keys
    
    # payment_type -> method_type
    method_params[:method_type] = method_params.delete(:payment_type)
    
    # credit_card_expires_on -> credit_card_exp_month + credit_card_exp_year
    if method_params[:credit_card_expires_on].present?
      expiry_date = Date.parse(method_params.delete(:credit_card_expires_on))
      method_params[:credit_card_exp_month] = expiry_date.month
      method_params[:credit_card_exp_year] = expiry_date.year
    end
    
    # Create temporary payment method
    payment_method = PaymentMethod.new(
      company: @invoice.company,
      owner: @invoice.contact,
      **method_params
    )
    
    # Save payment method so we can associate it with the payment
    unless payment_method.save
      return render json: { error: payment_method.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
    
    # Initialize Zego API
    zego_api = RenterInsightZegoApi.new(@invoice.company)
    
    # Register payment method with Zego to get external_id (GatewayPayerId)
    unless zego_api.create_account(payment_method, request)
      error_message = zego_api.payment_error_message
      return render json: { error: "Failed to register payment method: #{error_message}" }, status: :unprocessable_entity
    end
    
    # Update payment method with Zego's external_id
    payment_method.update!(
      external_id: zego_api.read_gateway_payer_id,
      api_partner_id: RenterInsightZegoApi::API_PARTNER_ID
    )
    
    # Create and SAVE payment record (must have ID for PaymentReferenceId)
    payment = Payment.create!(
      company: @invoice.company,
      location: @invoice.location,
      payer: @invoice.contact,
      amount: amount,
      payment_method: payment_method,
      status: 'processing'
    )
    # Application ties the payment to this invoice so it counts toward the
    # invoice's amount_paid once the payment lands in 'completed'.
    payment.apply_to!(@invoice, amount: amount)
    
    begin
      # Attempt to capture payment
      if zego_api.capture_one_time_payment(payment_method, payment, request)
        payment.update!(
          status: 'completed',
          processed_at: Time.current,
          external_id: zego_api.read_transaction_id,
          notes: 'Invoice payment via public payment page'
        )
        
        # Update invoice status to paid if fully paid
        @invoice.reload
        
        # Calculate total paid directly from database to avoid cache issues.
        # Sum application amounts, not payment totals — splits credit each
        # invoice only for its share.
        total_paid = @invoice.payment_applications
          .joins(:payment)
          .where(payments: { status: 'completed' })
          .sum(:amount)
        
        if total_paid >= @invoice.total
          @invoice.update!(status: 'paid', paid_at: Time.current)
        end
        
        # Send receipt email
        begin
          InvoiceMailer.payment_receipt(@invoice, payment).deliver_later
          Rails.logger.info "Payment receipt email queued for #{@invoice.contact.email}"
        rescue => email_error
          Rails.logger.error "Failed to queue receipt email: #{email_error.message}"
          # Don't fail the payment if email fails
        end
        
        render json: {
          success: true,
          message: 'Payment processed successfully',
          invoice: @invoice.as_json(include: [:invoice_items]),
          payment: payment
        }
      else
        # Mark payment as failed
        payment.update(status: 'failed', notes: zego_api.payment_error_message)
        error_message = zego_api.payment_error_message
        render json: { error: error_message }, status: :unprocessable_entity
      end
    rescue => e
      # Mark payment as failed on exception
      payment.update(status: 'failed', notes: e.message) if payment.persisted?
      Rails.logger.error "Invoice payment error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: 'Payment processing failed. Please try again.' }, status: :unprocessable_entity
    end
  end
  
  private
  
  def set_invoice
    @invoice = Invoice.find_by!(payment_token: params[:token])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Invoice not found' }, status: :not_found
  end
  
  def format_address(record)
    return nil unless record
    
    # Try different possible attribute names
    street = record.try(:street) || record.try(:address)
    city = record.try(:city)
    state = record.try(:state)
    zip = record.try(:zip) || record.try(:postal_code)
    
    parts = [street, city, state, zip].compact
    parts.present? ? parts.join(', ') : nil
  end
end
