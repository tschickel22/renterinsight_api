# frozen_string_literal: true

# QuickBooks Vendor Sync Handler
# Syncs vendors as QuickBooks Vendors

class QuickbooksVendorSyncHandler < QuickbooksSyncHandler
  def qb_entity_type
    'Vendor'
  end
  
  def get_all_syncable_records
    scope = company.vendors.where(is_deleted: [false, nil])
    scope = scope.where(location_id: location.id) if location.present?
    scope
  end

  def get_records_by_ids(ids)
    company.vendors.where(id: ids)
  end

  def get_records_by_quickbooks_ids(qb_ids)
    company.vendors.where(quickbooks_id: qb_ids)
  end

  def transform_to_quickbooks(vendor, config)
    # Vendor doesn't have first_name / last_name / company_name — it stores
    # a single display name and an optional contact_name for a human within
    # the vendor org. Send DisplayName as the vendor name and CompanyName
    # as the same (QB requires DisplayName to be unique across all name
    # lists; CompanyName is display-only).
    display = vendor.name.presence || "Vendor #{vendor.id}"

    payload = {
      DisplayName: display,
      CompanyName: display,
      PrimaryPhone: vendor.phone ? { FreeFormNumber: vendor.phone } : nil,
      PrimaryEmailAddr: vendor.email ? { Address: vendor.email } : nil,
      BillAddr: format_address(vendor),
      Active: vendor.status != 'inactive'
    }

    # For updates, echo current SyncToken back — QB rejects updates without it.
    if vendor.quickbooks_id.present?
      payload[:Id] = vendor.quickbooks_id
      payload[:SyncToken] = fetch_sync_token!('vendor', 'Vendor', vendor.quickbooks_id)
    end

    payload.compact
  end

  def find_by_quickbooks_id(qb_id)
    company.vendors.find_by(quickbooks_id: qb_id)
  end

  def create_from_quickbooks(qb_vendor, config)
    company.vendors.create!(
      quickbooks_id: qb_vendor['Id'],
      name:  qb_vendor['DisplayName'] || qb_vendor['CompanyName'] || "QB Vendor #{qb_vendor['Id']}",
      email: qb_vendor.dig('PrimaryEmailAddr', 'Address'),
      phone: qb_vendor.dig('PrimaryPhone', 'FreeFormNumber'),
      status: qb_vendor['Active'] ? 'active' : 'inactive',
      address_line1: qb_vendor.dig('BillAddr', 'Line1'),
      city:          qb_vendor.dig('BillAddr', 'City'),
      state:         qb_vendor.dig('BillAddr', 'CountrySubDivisionCode'),
      zip_code:      qb_vendor.dig('BillAddr', 'PostalCode'),
      country:       qb_vendor.dig('BillAddr', 'Country') || 'US',
      quickbooks_synced_at: Time.current
    )
  end

  def update_from_quickbooks(vendor, qb_vendor, config)
    vendor.update!(
      name:  qb_vendor['DisplayName'] || vendor.name,
      email: qb_vendor.dig('PrimaryEmailAddr', 'Address'),
      phone: qb_vendor.dig('PrimaryPhone', 'FreeFormNumber'),
      status: qb_vendor['Active'] ? 'active' : 'inactive',
      address_line1: qb_vendor.dig('BillAddr', 'Line1'),
      city:          qb_vendor.dig('BillAddr', 'City'),
      state:         qb_vendor.dig('BillAddr', 'CountrySubDivisionCode'),
      zip_code:      qb_vendor.dig('BillAddr', 'PostalCode'),
      country:       qb_vendor.dig('BillAddr', 'Country') || vendor.country,
      quickbooks_synced_at: Time.current
    )
  end

  private

  def format_address(vendor)
    return nil if vendor.address_line1.blank? && vendor.city.blank?

    {
      Line1: vendor.address_line1,
      City: vendor.city,
      CountrySubDivisionCode: vendor.state,
      PostalCode: vendor.zip_code,
      Country: vendor.country || 'USA'
    }.compact
  end
end
