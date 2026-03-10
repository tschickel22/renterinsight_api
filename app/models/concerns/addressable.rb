# frozen_string_literal: true

# Shared address logic for models with billing and delivery addresses.
# Handles different naming conventions across models:
#   - Contact: street/city/state/zip (billing), delivery_street/etc (delivery)
#   - Account: billing_street/etc, shipping_street/etc + postal_code
#   - Deal/Quote/Invoice: billing_street/etc, delivery_street/etc + zip
module Addressable
  extend ActiveSupport::Concern

  # ── Billing Address ──────────────────────────────────────────────

  def billing_address_hash
    {
      street: try(:billing_street),
      city: try(:billing_city),
      state: try(:billing_state),
      zip: try(:billing_zip) || try(:billing_postal_code),
      country: try(:billing_country)
    }
  end

  def billing_address_line
    parts = [
      try(:billing_street),
      try(:billing_city),
      try(:billing_state),
      try(:billing_zip) || try(:billing_postal_code)
    ]
    parts.compact.reject(&:blank?).join(', ')
  end

  def billing_address_present?
    (try(:billing_street).present? || try(:billing_city).present?)
  end

  # ── Delivery Address ─────────────────────────────────────────────

  def delivery_address_hash
    {
      street: try(:delivery_street),
      city: try(:delivery_city),
      state: try(:delivery_state),
      zip: try(:delivery_zip),
      country: try(:delivery_country)
    }
  end

  def delivery_address_line
    parts = [
      try(:delivery_street),
      try(:delivery_city),
      try(:delivery_state),
      try(:delivery_zip)
    ]
    parts.compact.reject(&:blank?).join(', ')
  end

  def delivery_address_present?
    (try(:delivery_street).present? || try(:delivery_city).present?)
  end

  # ── Copy Methods ─────────────────────────────────────────────────

  # Copy billing address from any source model.
  # Handles Contact (plain address), Account (billing_ prefix), Deal/Quote/Invoice (billing_ prefix).
  def copy_billing_address_from(source)
    if source.respond_to?(:billing_street)
      # Source has billing_ prefix (Account, Deal, Quote, Invoice)
      self.billing_street  = source.billing_street
      self.billing_city    = source.billing_city
      self.billing_state   = source.billing_state
      self.billing_zip     = source.try(:billing_zip) || source.try(:billing_postal_code)
      self.billing_country = source.billing_country
    elsif source.respond_to?(:street)
      # Source has plain address (Contact, Lead)
      self.billing_street  = source.street
      self.billing_city    = source.city
      self.billing_state   = source.state
      self.billing_zip     = source.zip
      self.billing_country = source.try(:country)
    end
  end

  # Copy delivery address from any source model.
  # Handles Contact (delivery_ prefix), Account (shipping_ prefix), Deal/Quote/Invoice (delivery_ prefix).
  def copy_delivery_address_from(source)
    if source.respond_to?(:delivery_street)
      self.delivery_street  = source.delivery_street
      self.delivery_city    = source.delivery_city
      self.delivery_state   = source.delivery_state
      self.delivery_zip     = source.delivery_zip
      self.delivery_country = source.try(:delivery_country)
    elsif source.respond_to?(:shipping_street)
      # Account uses shipping_ prefix and postal_code
      self.delivery_street  = source.shipping_street
      self.delivery_city    = source.shipping_city
      self.delivery_state   = source.shipping_state
      self.delivery_zip     = source.shipping_postal_code
      self.delivery_country = source.shipping_country
    end
  end

  # Copy both addresses from a single source
  def copy_all_addresses_from(source)
    copy_billing_address_from(source)
    copy_delivery_address_from(source)
  end

  # ── JSON Helpers ─────────────────────────────────────────────────

  def addresses_as_json
    {
      billing_address: billing_address_hash,
      delivery_address: delivery_address_hash
    }
  end
end
