# frozen_string_literal: true

# Sends a purchase order to the manufacturer or supplier, the PDF attached.
# Company-branded: it is the dealer's order, from the company's sender.
# Replies go to whoever sent it.
class PurchaseOrderMailer < ApplicationMailer
  # from: an address to send from instead of the company's sender (the
  # controller passes the platform's verified sender when the provider
  # rejects the company's as unverified).
  def order(po, to:, sender:, cc: nil, message: nil, from: nil)
    @po = po
    @company = po.company
    @location = po.location
    # The company's (or location's) sender, as quotes use: a person's own
    # sending address is often not verified with the mail provider. Replies
    # still go to the person who sent it.
    @sender = sender
    @message = message
    kind = po.factory_home? ? 'Home order' : 'Purchase order'
    attachments["#{po.po_number}.pdf"] = { mime_type: 'application/pdf', content: PurchaseOrderPdfGenerator.new(po).generate }
    # No From set at any level: ActionMailer's configured default.
    mail({ to: to, cc: cc.presence, reply_to: sender&.email, from: from || default_from_address,
           subject: "#{kind} #{po.po_number} from #{@company.name}" }.compact)
  end

  # A change to a factory order already sent (backlog E52), its PDF attached.
  def change_order(co, to:, sender:, cc: nil, message: nil, from: nil)
    @po = co.purchase_order
    @change_order = co
    @company = @po.company
    @location = @po.location
    @sender = sender
    @message = message
    attachments["#{co.label}.pdf"] = { mime_type: 'application/pdf', content: ChangeOrderPdfGenerator.new(co).generate }
    mail({ to: to, cc: cc.presence, reply_to: sender&.email, from: from || default_from_address,
           subject: "Change order #{co.label} from #{@company.name}" }.compact)
  end

  # The platform's sender (verified with the mail provider), shown under the
  # dealer's name.
  def self.platform_from(company)
    settings = Setting.get('Platform', 0, 'communications') || {}
    email = settings.is_a?(Hash) ? (settings.dig('email', 'fromEmail') || settings.dig('email', 'from_address')) : nil
    email.present? ? "#{company.name} <#{email}>" : nil
  end
end
