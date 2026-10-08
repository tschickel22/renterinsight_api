# frozen_string_literal: true

# Sends a purchase order to the manufacturer or supplier, the PDF attached.
# Company-branded: it is the dealer's order. Replies go to whoever sent it.
class PurchaseOrderMailer < ApplicationMailer
  def order(po, to:, sender:, cc: nil, message: nil)
    @po = po
    @company = po.company
    @location = po.location
    @sender_user = sender
    @message = message
    kind = po.factory_home? ? 'Home order' : 'Purchase order'
    attachments["#{po.po_number}.pdf"] = { mime_type: 'application/pdf', content: PurchaseOrderPdfGenerator.new(po).generate }
    # No From set at any level: ActionMailer's configured default.
    mail({ to: to, cc: cc.presence, reply_to: sender&.email, from: default_from_address,
           subject: "#{kind} #{po.po_number} from #{@company.name}" }.compact)
  end
end
