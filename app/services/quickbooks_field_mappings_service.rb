# frozen_string_literal: true

class QuickbooksFieldMappingsService
  # Default field mappings for each entity type
  DEFAULTS = {
    inventory: [
      { renter_insight_field: 'stock_number', quickbooks_field: 'Sku', mapping_type: 'direct', priority: 100 },
      { renter_insight_field: 'name', quickbooks_field: 'Name', mapping_type: 'computed', priority: 90,
        transformation_logic: { type: 'template', template: '{year} {make} {model}' } },
      { renter_insight_field: 'description', quickbooks_field: 'Description', mapping_type: 'direct', priority: 80 },
      { renter_insight_field: 'cost', quickbooks_field: 'PurchaseCost', mapping_type: 'direct', priority: 70 },
      { renter_insight_field: 'price', quickbooks_field: 'UnitPrice', mapping_type: 'direct', priority: 70 },
      { renter_insight_field: 'quantity_on_hand', quickbooks_field: 'QtyOnHand', mapping_type: 'direct', priority: 60 },
    ],
    
    customers: [
      { renter_insight_field: 'first_name', quickbooks_field: 'GivenName', mapping_type: 'direct', priority: 100 },
      { renter_insight_field: 'last_name', quickbooks_field: 'FamilyName', mapping_type: 'direct', priority: 100 },
      { renter_insight_field: 'display_name', quickbooks_field: 'DisplayName', mapping_type: 'computed', priority: 90,
        transformation_logic: { type: 'template', template: '{first_name} {last_name}' } },
      { renter_insight_field: 'email', quickbooks_field: 'PrimaryEmailAddr.Address', mapping_type: 'direct', priority: 80 },
      { renter_insight_field: 'phone', quickbooks_field: 'PrimaryPhone.FreeFormNumber', mapping_type: 'computed', priority: 70,
        transformation_logic: { type: 'format', format: 'phone' } },
      { renter_insight_field: 'street', quickbooks_field: 'BillAddr.Line1', mapping_type: 'direct', priority: 60 },
      { renter_insight_field: 'city', quickbooks_field: 'BillAddr.City', mapping_type: 'direct', priority: 60 },
      { renter_insight_field: 'state', quickbooks_field: 'BillAddr.CountrySubDivisionCode', mapping_type: 'direct', priority: 60 },
      { renter_insight_field: 'zip', quickbooks_field: 'BillAddr.PostalCode', mapping_type: 'direct', priority: 60 },
    ],
    
    invoices: [
      { renter_insight_field: 'invoice_number', quickbooks_field: 'DocNumber', mapping_type: 'direct', priority: 100 },
      { renter_insight_field: 'invoice_date', quickbooks_field: 'TxnDate', mapping_type: 'computed', priority: 90,
        transformation_logic: { type: 'format', format: 'date' } },
      { renter_insight_field: 'due_date', quickbooks_field: 'DueDate', mapping_type: 'computed', priority: 80,
        transformation_logic: { type: 'format', format: 'date' } },
      { renter_insight_field: 'subtotal', quickbooks_field: 'TotalAmt', mapping_type: 'direct', priority: 70 },
      { renter_insight_field: 'tax', quickbooks_field: 'TxnTaxDetail.TotalTax', mapping_type: 'direct', priority: 60 },
      { renter_insight_field: 'total', quickbooks_field: 'Balance', mapping_type: 'direct', priority: 50 },
    ],
    
    payments: [
      { renter_insight_field: 'payment_date', quickbooks_field: 'TxnDate', mapping_type: 'computed', priority: 100,
        transformation_logic: { type: 'format', format: 'date' } },
      { renter_insight_field: 'amount', quickbooks_field: 'TotalAmt', mapping_type: 'computed', priority: 90,
        transformation_logic: { type: 'format', format: 'currency' } },
      { renter_insight_field: 'payment_method', quickbooks_field: 'PaymentMethodRef.name', mapping_type: 'conditional', priority: 80,
        transformation_logic: { type: 'conditional',
          conditions: [
            { field: 'payment_type', operator: 'equals', value: 'credit_card', result: 'Credit Card' },
            { field: 'payment_type', operator: 'equals', value: 'ach', result: 'Check' },
            { field: 'payment_type', operator: 'equals', value: 'cash', result: 'Cash' },
          ],
          default: 'Other' } },
      { renter_insight_field: 'reference_number', quickbooks_field: 'PaymentRefNum', mapping_type: 'direct', priority: 70 },
    ],
    
    vendors: [
      { renter_insight_field: 'name', quickbooks_field: 'DisplayName', mapping_type: 'direct', priority: 100 },
      { renter_insight_field: 'email', quickbooks_field: 'PrimaryEmailAddr.Address', mapping_type: 'direct', priority: 80 },
      { renter_insight_field: 'phone', quickbooks_field: 'PrimaryPhone.FreeFormNumber', mapping_type: 'computed', priority: 70,
        transformation_logic: { type: 'format', format: 'phone' } },
      { renter_insight_field: 'street', quickbooks_field: 'BillAddr.Line1', mapping_type: 'direct', priority: 60 },
      { renter_insight_field: 'city', quickbooks_field: 'BillAddr.City', mapping_type: 'direct', priority: 60 },
      { renter_insight_field: 'state', quickbooks_field: 'BillAddr.CountrySubDivisionCode', mapping_type: 'direct', priority: 60 },
      { renter_insight_field: 'zip', quickbooks_field: 'BillAddr.PostalCode', mapping_type: 'direct', priority: 60 },
    ],
    
    purchases: [
      { renter_insight_field: 'bill_number', quickbooks_field: 'DocNumber', mapping_type: 'direct', priority: 100 },
      { renter_insight_field: 'bill_date', quickbooks_field: 'TxnDate', mapping_type: 'computed', priority: 90,
        transformation_logic: { type: 'format', format: 'date' } },
      { renter_insight_field: 'due_date', quickbooks_field: 'DueDate', mapping_type: 'computed', priority: 80,
        transformation_logic: { type: 'format', format: 'date' } },
      { renter_insight_field: 'total', quickbooks_field: 'TotalAmt', mapping_type: 'computed', priority: 70,
        transformation_logic: { type: 'format', format: 'currency' } },
    ],
  }.freeze
  
  def self.create_defaults_for_company(company)
    DEFAULTS.each do |entity_type, mappings|
      mappings.each do |mapping_attrs|
        company.quickbooks_field_mappings.find_or_create_by!(
          location_id: nil,  # CRITICAL: Must explicitly set to nil for company-wide
          entity_type: entity_type.to_s,
          renter_insight_field: mapping_attrs[:renter_insight_field]
        ) do |mapping|
          mapping.quickbooks_field = mapping_attrs[:quickbooks_field]
          mapping.mapping_type = mapping_attrs[:mapping_type]
          mapping.priority = mapping_attrs[:priority]
          mapping.transformation_logic = mapping_attrs[:transformation_logic]&.to_json
          mapping.enabled = true
        end
      end
    end
  end
  
  def self.create_defaults_for_location(location)
    DEFAULTS.each do |entity_type, mappings|
      mappings.each do |mapping_attrs|
        location.company.quickbooks_field_mappings.find_or_create_by!(
          location_id: location.id,
          entity_type: entity_type.to_s,
          renter_insight_field: mapping_attrs[:renter_insight_field]
        ) do |mapping|
          mapping.quickbooks_field = mapping_attrs[:quickbooks_field]
          mapping.mapping_type = mapping_attrs[:mapping_type]
          mapping.priority = mapping_attrs[:priority]
          mapping.transformation_logic = mapping_attrs[:transformation_logic]&.to_json
          mapping.enabled = true
        end
      end
    end
  end
  
  def self.get_mappings_for_entity(company, entity_type, location_id: nil)
    # Return ALL mappings (enabled and disabled) so users can toggle them
    mappings = company.quickbooks_field_mappings.for_entity(entity_type).by_priority
    
    if location_id.present?
      # Get location-specific mappings first, fall back to company-wide
      location_mappings = mappings.where(location_id: location_id)
      company_mappings = mappings.where(location_id: nil)
      
      # Merge, preferring location-specific
      merged = {}
      company_mappings.each { |m| merged[m.renter_insight_field] = m }
      location_mappings.each { |m| merged[m.renter_insight_field] = m }
      merged.values
    else
      mappings.where(location_id: nil).to_a
    end
  end
  
  def self.apply_mappings(entity, entity_type, company, location_id: nil)
    # Get ALL mappings but only use enabled ones for actual sync
    all_mappings = get_mappings_for_entity(company, entity_type, location_id: location_id)
    mappings = all_mappings.select(&:enabled)
    
    result = {}
    mappings.each do |mapping|
      value = entity.send(mapping.renter_insight_field) rescue nil
      next if value.nil?
      
      context = entity.attributes.symbolize_keys
      transformed_value = mapping.transform_value(value, context)
      
      # Handle nested QB fields (e.g., "BillAddr.Line1")
      set_nested_value(result, mapping.quickbooks_field, transformed_value)
    end
    
    result
  end
  
  private
  
  def self.set_nested_value(hash, path, value)
    keys = path.split('.')
    last_key = keys.pop
    
    # Navigate/create nested structure
    current = hash
    keys.each do |key|
      current[key] ||= {}
      current = current[key]
    end
    
    current[last_key] = value
  end
end
