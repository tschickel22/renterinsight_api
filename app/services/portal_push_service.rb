# frozen_string_literal: true

# Named portal push events, one method per thing a customer is waiting on.
#
# Every method here is fire-and-forget: a push that fails must never take down
# the email/SMS/record-keeping it rides alongside, so each rescues and logs.
# Callers get true/false and are free to ignore it.
#
# Copy lives here rather than at the call sites so the tone stays consistent
# across the portal, and so a wording change is one edit.
class PortalPushService
  class << self
    # A document is waiting on their signature. The single most time-sensitive
    # portal event: a deal stalls until this is done.
    def document_to_sign(agreement:, signer:)
      access = access_for_email(agreement.company_id, signer.email)
      return false if access.blank?

      deliver(
        access,
        event: 'document_to_sign',
        title: 'Document ready to sign',
        body: "#{dealer_name(agreement)} sent you \"#{agreement.title}\" to review and sign.",
        path: "agreements/#{agreement.id}",
        priority: 'high',
        collapse_key: "agreement:#{agreement.id}",
        data: { agreement_id: agreement.id, signer_id: signer.id }
      )
    end

    # A signing request that has gone unanswered. Same collapse key as the
    # original so the reminder replaces it in the tray instead of stacking.
    def document_signature_reminder(agreement:, signer:)
      access = access_for_email(agreement.company_id, signer.email)
      return false if access.blank?

      deliver(
        access,
        event: 'document_signature_reminder',
        title: 'Reminder: document still needs your signature',
        body: "\"#{agreement.title}\" from #{dealer_name(agreement)} is still waiting on you.",
        path: "agreements/#{agreement.id}",
        priority: 'normal',
        collapse_key: "agreement:#{agreement.id}",
        data: { agreement_id: agreement.id, signer_id: signer.id }
      )
    end

    def new_invoice(invoice:, buyer: nil)
      buyer ||= invoice.try(:contact)
      access = access_for_buyer(buyer)
      return false if access.blank?

      deliver(
        access,
        event: 'invoice_created',
        title: 'New invoice',
        body: "#{dealer_name(invoice)} sent you invoice #{invoice.try(:invoice_number) || "##{invoice.id}"}#{amount_suffix(invoice)}.",
        path: 'invoices',
        priority: 'normal',
        collapse_key: "invoice:#{invoice.id}",
        data: { invoice_id: invoice.id }
      )
    end

    def invoice_overdue(invoice:, buyer: nil)
      buyer ||= invoice.try(:contact)
      access = access_for_buyer(buyer)
      return false if access.blank?

      deliver(
        access,
        event: 'invoice_overdue',
        title: 'Invoice past due',
        body: "Invoice #{invoice.try(:invoice_number) || "##{invoice.id}"}#{amount_suffix(invoice)} is past its due date.",
        path: 'invoices',
        priority: 'high',
        collapse_key: "invoice:#{invoice.id}",
        data: { invoice_id: invoice.id }
      )
    end

    # A dealer uploaded something to the customer's document library.
    def new_document(document:, buyer: nil)
      # PortalDocument#owner is the Contact, not the portal login.
      buyer ||= document.try(:owner) || document.try(:contact)
      access = access_for_buyer(buyer)
      return false if access.blank?

      document_name = document.try(:document_name).presence ||
                      document.try(:name).presence ||
                      document.try(:title).presence ||
                      'A document'

      deliver(
        access,
        event: 'document_shared',
        title: 'New document available',
        body: "#{document_name} was added to your portal.",
        path: 'documents',
        priority: 'normal',
        collapse_key: "document:#{document.id}",
        data: { document_id: document.id }
      )
    end

    def new_quote(quote:, buyer: nil)
      buyer ||= quote.try(:contact)
      access = access_for_buyer(buyer)
      return false if access.blank?

      deliver(
        access,
        event: 'quote_ready',
        title: 'Your quote is ready',
        body: "#{dealer_name(quote)} sent you quote #{quote.try(:quote_number) || "##{quote.id}"} to review.",
        path: 'quotes',
        priority: 'high',
        collapse_key: "quote:#{quote.id}",
        data: { quote_id: quote.id }
      )
    end

    # A reply from the dealership in the portal message thread.
    def new_message(communication:, buyer: nil)
      buyer ||= communication.try(:communicable)
      access = access_for_buyer(buyer)
      return false if access.blank?

      deliver(
        access,
        event: 'message_received',
        title: "Message from #{dealer_name(communication)}",
        body: message_preview(communication),
        # No dedicated messages route in the portal SPA yet, so this lands on
        # the dashboard rather than a 404. Point it at 'messages' once that
        # page exists.
        path: nil,
        priority: 'high',
        collapse_key: 'messages',
        data: { communication_id: communication.id }
      )
    end

    # Work in a project is waiting on the customer's approval. The project side
    # identifies the client by email rather than by a portal record, so this
    # accepts either.
    def approval_requested(project:, assignment:, buyer: nil, client_email: nil)
      access = access_for_buyer(buyer) || access_for_email(project.try(:company_id), client_email)
      return false if access.blank?

      deliver(
        access,
        event: 'approval_requested',
        title: 'Work ready for your review',
        body: "#{assignment.try(:title) || 'Completed work'} on #{project.try(:name) || 'your project'} is waiting for your approval.",
        path: 'progress',
        priority: 'high',
        collapse_key: "assignment:#{assignment&.id}",
        data: { project_id: project&.id, assignment_id: assignment&.id }
      )
    end

    private

    def deliver(access, **args)
      PushNotificationService.notify_portal(buyer_access: access, **args)
    rescue StandardError => e
      Rails.logger.error("[PortalPush] #{args[:event]} failed for access #{access&.id}: #{e.message}")
      false
    end

    # Signers are identified by email, not by a portal id, so this is the join
    # back to a portal login. Scoped by company because the same person can be a
    # customer of two dealers on the platform.
    def access_for_email(company_id, email)
      return nil if email.blank?

      BuyerPortalAccess.find_by(company_id: company_id, email: email.to_s.strip.downcase) ||
        BuyerPortalAccess.find_by(email: email.to_s.strip.downcase)
    end

    def access_for_buyer(buyer)
      return nil if buyer.blank?
      return buyer if buyer.is_a?(BuyerPortalAccess)

      BuyerPortalAccess.find_by(buyer_type: buyer.class.name, buyer_id: buyer.id)
    end

    # The dealership's name, not the platform's: the customer knows the dealer.
    def dealer_name(record)
      record.try(:company)&.name.presence || Brand.current.name
    end

    def amount_suffix(invoice)
      amount = invoice.try(:total) || invoice.try(:total_amount) || invoice.try(:amount)
      return '' if amount.blank?

      " for #{ActionController::Base.helpers.number_to_currency(amount)}"
    end

    def message_preview(communication)
      raw = communication.try(:body).presence || communication.try(:content).presence || 'You have a new message.'
      ActionView::Base.full_sanitizer.sanitize(raw.to_s).squish.truncate(140)
    end
  end
end
