# frozen_string_literal: true

# Namespaced resolver used by the inventory-side posting services
# (PurchaseOrder, PartsUsage, VehicleInventory).
# Note: the top-level ::AccountLinkResolver (Phase 1C) is the long-standing
# resolver used by InvoicePosting/PaymentPosting/DealAccounting and has a
# different lookup chain (entity → entity-type → location → settings).
# This class is a simpler 2-step lookup per the inventory spec.
module Accounting
  class AccountLinkResolver
    def self.resolve(company:, entity:, purpose:)
      link = company.account_links.active
                    .where(linkable: entity, link_purpose: purpose)
                    .by_priority.first

      if link.nil? && entity.present?
        link = company.account_links.active
                      .where(linkable_type: entity.class.name, linkable_id: nil, link_purpose: purpose)
                      .by_priority.first
      end

      link&.chart_of_account
    end
  end
end
