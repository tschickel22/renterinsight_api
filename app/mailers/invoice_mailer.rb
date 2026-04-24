class InvoiceMailer < ApplicationMailer
  def payment_receipt(invoice, payment)
    @invoice = invoice
    @payment = payment
    @company = invoice.company
    @location = invoice.location
    @contact = invoice.contact

    @subtotal = @invoice.subtotal
    @total = @invoice.total
    @amount_paid = payment.amount
    @balance_due = @invoice.amount_due

    deliver_with_resolved_config(
      to: @contact.email,
      subject: "Payment Receipt - Invoice #{@invoice.invoice_number}"
    )
  end

  def invoice_email(invoice)
    @invoice = invoice
    @company = invoice.company
    @location = invoice.location
    @contact = invoice.contact

    @subtotal = @invoice.subtotal
    @total = @invoice.total
    @amount_due = @invoice.amount_due

    @payment_link = @invoice.payment_url
    @payments_enabled = @company.external_payments_id.present?

    deliver_with_resolved_config(
      to: @contact.email,
      subject: "Invoice #{@invoice.invoice_number} from #{@company.name}"
    )
  end

  private

  # Resolves per-send SMTP/provider credentials from the company/location
  # communications settings via MailerDeliveryConfigurator, then applies them
  # directly to the Mail::Message. Matches the pattern used by SocialPostMailer.
  # Without this, ActionMailer falls back to the boot-time global SMTP settings
  # cached by config/initializers/action_mailer_platform_settings.rb, which go
  # stale after the user reconnects their mailbox.
  def deliver_with_resolved_config(to:, subject:)
    delivery = MailerDeliveryConfigurator.resolve(company: @company, location: @location)

    mail_opts = { to: to, subject: subject }

    if delivery && (from_email = delivery[:from_address].presence)
      from_name        = delivery[:from_name].presence
      mail_opts[:from] = from_name.present? ? "#{from_name} <#{from_email}>" : from_email
    end

    mail_opts[:from] ||= default_from_address
    message = mail(**mail_opts)

    if delivery && message
      message.delivery_method(delivery[:delivery_method], delivery[:delivery_method_options])
    end

    message
  end
end
