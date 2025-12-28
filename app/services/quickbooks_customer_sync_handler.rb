# frozen_string_literal: true

# QuickBooks Customer Sync Handler
# Syncs contacts as QuickBooks Customers

class QuickbooksCustomerSyncHandler < QuickbooksSyncHandler
  def qb_entity_type
    'Customer'
  end
  
  def get_all_syncable_records
    # Get contacts from company or location
    # Note: Contact model doesn't have is_deleted field
    scope = company.contacts
    
    # Filter by location if needed
    scope = scope.where(location_id: location.id) if location.present?
    
    scope
  end
  
  def get_records_by_ids(ids)
    company.contacts.where(id: ids)
  end
  
  def transform_to_quickbooks(contact, config)
    # Get company name from account if available
    company_name = if contact.respond_to?(:account) && contact.account.present?
      contact.account.name
    elsif contact.respond_to?(:company_name)
      contact.company_name
    else
      nil
    end
    
    # Map contact to QuickBooks Customer format
    {
      DisplayName: contact.display_name || "#{contact.first_name} #{contact.last_name}",
      GivenName: contact.first_name,
      FamilyName: contact.last_name,
      CompanyName: company_name,
      PrimaryPhone: format_phone(contact.phone),
      Mobile: nil,  # Contact model doesn't have cell_phone field
      PrimaryEmailAddr: contact.email ? { Address: contact.email } : nil,
      BillAddr: format_address(contact, 'billing'),
      ShipAddr: format_address(contact, 'shipping'),
      Notes: contact.notes,
      Active: true,  # Contacts don't have a status field
      # Custom fields
      CustomField: [
        {
          DefinitionId: '1',
          Name: 'Contact Type',
          Type: 'StringType',
          StringValue: contact.contact_type
        }
      ].compact
    }.compact
  end
  
  def find_by_quickbooks_id(qb_id)
    company.contacts.find_by(quickbooks_id: qb_id)
  end
  
  def create_from_quickbooks(qb_customer, config)
    # Extract data from QuickBooks Customer
    contact_data = {
      company_id: company.id,
      location_id: location&.id,
      quickbooks_id: qb_customer['Id'],
      first_name: qb_customer['GivenName'],
      last_name: qb_customer['FamilyName'],
      company_name: qb_customer['CompanyName'],
      email: qb_customer.dig('PrimaryEmailAddr', 'Address'),
      phone: parse_phone(qb_customer['PrimaryPhone']),
      notes: qb_customer['Notes'],
      quickbooks_synced_at: Time.current
    }
    
    # Parse address
    if qb_customer['BillAddr']
      contact_data.merge!(parse_address(qb_customer['BillAddr'], 'billing'))
    end
    
    company.contacts.create!(contact_data)
  end
  
  def update_from_quickbooks(contact, qb_customer, config)
    update_data = {
      first_name: qb_customer['GivenName'],
      last_name: qb_customer['FamilyName'],
      company_name: qb_customer['CompanyName'],
      email: qb_customer.dig('PrimaryEmailAddr', 'Address'),
      phone: parse_phone(qb_customer['PrimaryPhone']),
      notes: qb_customer['Notes'],
      quickbooks_synced_at: Time.current
    }
    
    # Parse address
    if qb_customer['BillAddr']
      update_data.merge!(parse_address(qb_customer['BillAddr'], 'billing'))
    end
    
    contact.update!(update_data)
  end
  
  private
  
  def format_phone(phone)
    return nil if phone.blank?
    
    # Format as QuickBooks PhoneNumber object
    {
      FreeFormNumber: phone
    }
  end
  
  def parse_phone(phone_obj)
    phone_obj&.dig('FreeFormNumber')
  end
  
  def format_address(contact, type)
    # Contact model only has single address (not separate billing/shipping)
    # Use the contact's address for both billing and shipping
    street = contact.street
    city = contact.city
    state = contact.state
    zip = contact.zip
    country = contact.country
    
    return nil if street.blank? && city.blank?
    
    {
      Line1: street,
      City: city,
      CountrySubDivisionCode: state,
      PostalCode: zip,
      Country: country.present? ? country : 'USA'
    }.compact
  end
  
  def parse_address(addr_obj, type)
    # Contact model only has single address (not separate billing/shipping)
    # Map QuickBooks address to contact's address fields
    {
      "street" => addr_obj['Line1'],
      "city" => addr_obj['City'],
      "state" => addr_obj['CountrySubDivisionCode'],
      "zip" => addr_obj['PostalCode'],
      "country" => addr_obj['Country']
    }.compact
  end
end
