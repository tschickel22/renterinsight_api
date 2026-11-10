# frozen_string_literal: true

# Picks the GL account a posting should use from the company's account links
# (Accounting Settings, Account Mappings). Used by deal closing, invoice and
# purchase order posting. Inside module Accounting a bare AccountLinkResolver
# means this class, not the top-level ::AccountLinkResolver. Most specific wins:
#
#   1. A link on this exact record (this Part, this Vehicle, this Deal).
#   2. A link on the Location the posting belongs to, when the caller passes
#      location_id. This is the only kind of mapping the settings screen
#      creates today.
#   3. A type-wide link (linkable_type is the record's class, no id).
#   4. nil: the caller falls back to the Accounting Settings default.
#
# Within one step the higher priority wins, as the mapping form explains.
#
# The top-level ::AccountLinkResolver also checks VehicleType / DealType
# links before Location. Those are keyed by a string while linkable_id is a
# bigint, so they can never match and are left out here.
module Accounting
  class AccountLinkResolver
    def self.resolve(company:, entity:, purpose:, location_id: nil)
      links = company.account_links.active
                     .where(link_purpose: purpose)
                     .order(priority: :desc, id: :asc)

      link = links.find_by(linkable: entity) if entity.present?

      if link.nil? && location_id.present?
        link = links.find_by(linkable_type: 'Location', linkable_id: location_id)
      end

      if link.nil? && entity.present?
        link = links.find_by(linkable_type: entity.class.name, linkable_id: nil)
      end

      link&.chart_of_account
    end
  end
end
