# frozen_string_literal: true

class AccountLinkResolver
  # Resolution order (most specific wins):
  # 1. Specific Entity Link     → AccountLink for this exact Vehicle/Deal/Contact
  # 2. Entity-Type Link         → AccountLink for VehicleType or DealType
  # 3. Location Link            → AccountLink for this Location's default
  # 4. Company Default          → AccountingSettings.default_*_account
  # 5. System Fallback          → nil (caller must handle)

  def self.resolve(company:, entity:, purpose:)
    link = company.account_links.active.find_by(
      linkable: entity, link_purpose: purpose
    )
    return link.chart_of_account if link

    if entity.respond_to?(:vehicle_type) && entity.vehicle_type.present?
      link = company.account_links.active.find_by(
        linkable_type: 'VehicleType', linkable_id: entity.vehicle_type,
        link_purpose: purpose
      )
      return link.chart_of_account if link
    end

    if entity.respond_to?(:deal_type) && entity.deal_type.present?
      link = company.account_links.active.find_by(
        linkable_type: 'DealType', linkable_id: entity.deal_type,
        link_purpose: purpose
      )
      return link.chart_of_account if link
    end

    if entity.respond_to?(:location_id) && entity.location_id.present?
      link = company.account_links.active.find_by(
        linkable_type: 'Location', linkable_id: entity.location_id,
        link_purpose: purpose
      )
      return link.chart_of_account if link
    end

    settings = company.accounting_settings
    return nil unless settings

    case purpose
    when 'revenue'    then settings.default_sales_revenue_account
    when 'cogs'       then settings.default_cogs_account
    when 'receivable' then settings.default_ar_account
    when 'payable'    then settings.default_ap_account
    end
  end
end
