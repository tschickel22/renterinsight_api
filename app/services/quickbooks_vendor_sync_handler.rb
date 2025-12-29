# frozen_string_literal: true

# QuickBooks Vendor Sync Handler
# Syncs vendors as QuickBooks Vendors

class QuickbooksVendorSyncHandler < QuickbooksSyncHandler
  def qb_entity_type
    'Vendor'
  end
  
  def get_all_syncable_records
    # Get vendors from company or location if table exists
    return [] unless defined?(Vendor)
    
    scope = company.vendors.where(is_deleted: [false, nil])
    scope = scope.where(location_id: location.id) if location.present?
    scope
  end
  
  def get_records_by_ids(ids)
    return [] unless defined?(Vendor)
    company.vendors.where(id: ids)
  end
  
  def transform_to_quickbooks(vendor, config)
    {
      DisplayName: vendor.name || "#{vendor.first_name} #{vendor.last_name}",
      CompanyName: vendor.company_name,
      GivenName: vendor.first_name,
      FamilyName: vendor.last_name,
      PrimaryPhone: vendor.phone ? { FreeFormNumber: vendor.phone } : nil,
      PrimaryEmailAddr: vendor.email ? { Address: vendor.email } : nil,
      BillAddr: format_address(vendor),
      Active: vendor.status != 'inactive'
    }.compact
  end
  
  def find_by_quickbooks_id(qb_id)
    return nil unless defined?(Vendor)
    company.vendors.find_by(quickbooks_id: qb_id)
  end
  
  def create_from_quickbooks(qb_vendor, config)
    return nil unless defined?(Vendor)
    
    vendor_data = {
      company_id: company.id,
      location_id: location&.id,
      quickbooks_id: qb_vendor['Id'],
      name: qb_vendor['DisplayName'],
      company_name: qb_vendor['CompanyName'],
      first_name: qb_vendor['GivenName'],
      last_name: qb_vendor['FamilyName'],
      email: qb_vendor.dig('PrimaryEmailAddr', 'Address'),
      phone: qb_vendor.dig('PrimaryPhone', 'FreeFormNumber'),
      status: qb_vendor['Active'] ? 'active' : 'inactive',
      quickbooks_synced_at: Time.current
    }
    
    company.vendors.create!(vendor_data)
  end
  
  def update_from_quickbooks(vendor, qb_vendor, config)
    vendor.update!(
      name: qb_vendor['DisplayName'],
      company_name: qb_vendor['CompanyName'],
      email: qb_vendor.dig('PrimaryEmailAddr', 'Address'),
      phone: qb_vendor.dig('PrimaryPhone', 'FreeFormNumber'),
      status: qb_vendor['Active'] ? 'active' : 'inactive',
      quickbooks_synced_at: Time.current
    )
  end
  
  private
  
  def format_address(vendor)
    return nil if vendor.street.blank? && vendor.city.blank?
    
    {
      Line1: vendor.street,
      City: vendor.city,
      CountrySubDivisionCode: vendor.state,
      PostalCode: vendor.zip,
      Country: vendor.country || 'USA'
    }.compact
  end
end
