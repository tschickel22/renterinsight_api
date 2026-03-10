# frozen_string_literal: true

# Copies billing/delivery addresses and co-buyers through the DMS pipeline.
#
# Pipeline:  Lead → Contact → Deal → Quote → Invoice → Agreement
#
# Usage:
#   PipelineCopyService.contact_to_deal(contact, deal)
#   PipelineCopyService.deal_to_quote(deal, quote)
#   PipelineCopyService.quote_to_invoice(quote, invoice)
#
class PipelineCopyService

  # ── Lead → Contact ────────────────────────────────────────────────
  # Called during lead conversion. Copies the lead's single address
  # to the contact's billing (primary) address.
  def self.lead_to_contact(lead, contact)
    contact.street  = lead.street  if lead.street.present?  && contact.street.blank?
    contact.city    = lead.city    if lead.city.present?    && contact.city.blank?
    contact.state   = lead.state   if lead.state.present?   && contact.state.blank?
    contact.zip     = lead.zip     if lead.zip.present?     && contact.zip.blank?
    contact.country = lead.try(:country) if lead.try(:country).present? && contact.try(:country).blank?
  end

  # ── Contact → Account ────────────────────────────────────────────
  # Called when creating an account from a contact.
  def self.contact_to_account(contact, account)
    # Contact's primary address → Account billing address
    if contact.street.present? && account.billing_street.blank?
      account.billing_street      = contact.street
      account.billing_city        = contact.city
      account.billing_state       = contact.state
      account.billing_postal_code = contact.zip
      account.billing_country     = contact.try(:country)
    end

    # Contact's delivery address → Account shipping address
    if contact.try(:delivery_street).present? && account.shipping_street.blank?
      account.shipping_street      = contact.delivery_street
      account.shipping_city        = contact.delivery_city
      account.shipping_state       = contact.delivery_state
      account.shipping_postal_code = contact.delivery_zip
      account.shipping_country     = contact.try(:delivery_country)
    end
  end

  # ── Contact → Deal ──────────────────────────────────────────────
  # Called when creating a deal from a contact or lead.
  def self.contact_to_deal(contact, deal)
    deal.contact_id    = contact.id
    deal.customer_name = "#{contact.first_name} #{contact.last_name}".strip

    # Contact primary address → Deal billing address
    deal.billing_street  = contact.street
    deal.billing_city    = contact.city
    deal.billing_state   = contact.state
    deal.billing_zip     = contact.zip
    deal.billing_country = contact.try(:country)

    # Contact delivery address → Deal delivery address (if present)
    if contact.try(:delivery_street).present?
      deal.delivery_street  = contact.delivery_street
      deal.delivery_city    = contact.delivery_city
      deal.delivery_state   = contact.delivery_state
      deal.delivery_zip     = contact.delivery_zip
      deal.delivery_country = contact.try(:delivery_country)
    end
  end

  # ── Deal → Quote ────────────────────────────────────────────────
  # Called when creating a quote from a deal.
  def self.deal_to_quote(deal, quote)
    quote.contact_id = deal.contact_id
    quote.account_id = deal.account_id
    quote.deal_id    = deal.id

    # Copy both addresses
    quote.copy_all_addresses_from(deal)

    # Copy co-buyers
    quote.copy_buyers_from(deal)
  end

  # ── Quote → Invoice ─────────────────────────────────────────────
  # Called when generating an invoice from a quote.
  def self.quote_to_invoice(quote, invoice)
    invoice.contact_id = quote.contact_id
    invoice.deal_id    = quote.deal_id
    invoice.quote_id   = quote.id

    # Copy both addresses
    invoice.copy_all_addresses_from(quote)

    # Copy co-buyers
    invoice.copy_buyers_from(quote)
  end

  # ── Deal → Invoice (direct, no quote) ──────────────────────────
  # For cases where invoice is created directly from a deal.
  def self.deal_to_invoice(deal, invoice)
    invoice.contact_id = deal.contact_id
    invoice.deal_id    = deal.id

    # Copy both addresses
    invoice.copy_all_addresses_from(deal)

    # Copy co-buyers
    invoice.copy_buyers_from(deal)
  end
end
