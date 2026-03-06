class InvoiceMailer < ApplicationMailer
  def payment_receipt(invoice, payment)
    @invoice = invoice
    @payment = payment
    @company = invoice.company
    @location = invoice.location
    @contact = invoice.contact
    
    # Calculate invoice totals
    @subtotal = @invoice.subtotal
    @total = @invoice.total
    @amount_paid = payment.amount
    @balance_due = @invoice.amount_due
    
    mail(
      to: @contact.email,
      from: default_from_address,
      subject: "Payment Receipt - Invoice #{@invoice.invoice_number}"
    )
  end
  
  def invoice_email(invoice)
    @invoice = invoice
    @company = invoice.company
    @location = invoice.location
    @contact = invoice.contact
    
    # Calculate invoice totals
    @subtotal = @invoice.subtotal
    @total = @invoice.total
    @amount_due = @invoice.amount_due
    
    # Payment link for template
    @payment_link = @invoice.payment_url
    @payments_enabled = @company.external_payments_id.present?
    
    mail(
      to: @contact.email,
      from: default_from_address,
      subject: "Invoice #{@invoice.invoice_number} from #{@company.name}"
    )
  end
end
