# frozen_string_literal: true
# Public invoice access for contacts via portal
class Public::InvoicesController < ActionController::Base
  # No authentication required - inherits from ActionController::Base, not ApplicationController
  
  # GET /public/invoices/:token
  def show
    @invoice = Invoice.find_by_public_token!(params[:token])
    
    # Mark as viewed if currently sent
    @invoice.mark_as_viewed! if @invoice.status == 'sent'
    
    render json: {
      invoice: @invoice.as_json(
        only: [:id, :invoice_number, :invoice_date, :due_date, :subtotal, :tax_amount, :tax_rate, :total, :amount_due, :amount_paid, :status, :notes, :terms, :footer_text],
        include: {
          company: {
            only: [:id, :name, :phone, :email, :website],
            methods: [:logo_url, :address_line1, :address_line2]
          },
          location: {
            only: [:id, :name, :phone, :email],
            methods: [:address_line1, :address_line2]
          },
          contact: {
            only: [:id, :first_name, :last_name, :email, :phone]
          },
          invoice_items: {
            only: [:id, :item_type, :description, :quantity, :rate, :amount, :position]
          },
          loan: {
            only: [:id, :loan_number, :loan_type],
            methods: [:display_name]
          }
        },
        methods: [:payment_url, :is_overdue]
      )
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Invoice not found' }, status: :not_found
  end
  
  # GET /public/invoices/:token/pdf
  def pdf
    @invoice = Invoice.find_by_public_token!(params[:token])
    
    # Generate PDF (you'll need to implement this)
    # For now, just return not implemented
    render json: { error: 'PDF generation not yet implemented' }, status: :not_implemented
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Invoice not found' }, status: :not_found
  end
end
