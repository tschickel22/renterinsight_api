# frozen_string_literal: true

# QuickBooks Customer Sync Handler
# Syncs contacts as QuickBooks Customers

class QuickbooksCustomerSyncHandler < QuickbooksSyncHandler
  def qb_entity_type
    'Customer'
  end
  
  def get_all_syncable_records
    # Get contacts from company or location
    scope = company.contacts.where(is_deleted: [false, nil])
    
    # Filter by location if needed
    scope = scope.where(location_id: location.id) if location.present?
    
    scope
  end
  
  def get_records_by_ids(ids)
    company.contacts.where(id: ids)
  end
  
  def transform_to_quickbooks(contact, config, unique_suffix: nil)
    # Get company name from account if available
    company_name = if contact.respond_to?(:account) && contact.account.present?
      contact.account.name
    elsif contact.respond_to?(:company_name)
      contact.company_name
    else
      nil
    end

    # Build unique DisplayName - QB requires unique across Customers, Vendors, and Employees
    display_name = build_unique_display_name(contact, unique_suffix)

    # Base customer data
    data = {
      DisplayName: display_name,
      GivenName: contact.first_name,
      FamilyName: contact.last_name,
      CompanyName: company_name,
      PrimaryPhone: format_phone(contact.phone),
      Mobile: nil,
      PrimaryEmailAddr: contact.email ? { Address: contact.email } : nil,
      BillAddr: format_address(contact, 'billing'),
      ShipAddr: format_address(contact, 'shipping'),
      Notes: contact.notes,
      Active: true
    }.compact
    
    # For updates, include Id and fetch SyncToken from QB
    if contact.quickbooks_id.present?
      data[:Id] = contact.quickbooks_id
      
      # Fetch current customer to get SyncToken
      begin
        # Use lowercase 'customer' endpoint (QB API is case-sensitive)
        qb_customer = @api.get_entity('customer', contact.quickbooks_id)
        data[:SyncToken] = qb_customer['Customer']['SyncToken']
      rescue => e
        Rails.logger.error "[QB Sync] Failed to fetch customer #{contact.quickbooks_id}: #{e.message}"
        raise "Cannot update QB customer without SyncToken: #{e.message}"
      end
    end
    
    data
  end
  
  def find_by_quickbooks_id(qb_id)
    company.contacts.find_by(quickbooks_id: qb_id)
  end

  def get_records_by_quickbooks_ids(qb_ids)
    company.contacts.where(quickbooks_id: qb_ids)
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
  
  # Build a unique DisplayName for QB. QB requires uniqueness across
  # Customers, Vendors, and Employees. Strategy in order of user-visibility:
  #   1. base name        — the ideal
  #   2. base + email     — still readable in QB dropdowns
  #   3. base + " — RI#<id>" — always unique per contact, guaranteed to
  #      resolve any residual collision (two contacts with the same name
  #      AND the same email, or a collision against a QB Vendor with the
  #      same email address).
  def build_unique_display_name(contact, suffix = nil)
    base_name = contact.display_name.presence || "#{contact.first_name} #{contact.last_name}".strip
    base_name = "Contact #{contact.id}" if base_name.blank?

    case suffix
    when :email
      contact.email.present? ? "#{base_name} - #{contact.email}" : "#{base_name} — RI##{contact.id}"
    when :id
      "#{base_name} — RI##{contact.id}"
    else
      base_name
    end
  end

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
