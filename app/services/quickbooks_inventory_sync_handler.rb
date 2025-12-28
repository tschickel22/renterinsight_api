# frozen_string_literal: true

# QuickBooks Inventory Sync Handler
# Syncs vehicles/RVs as QuickBooks Items (Inventory or Non-Inventory)

class QuickbooksInventorySyncHandler < QuickbooksSyncHandler
  def qb_entity_type
    'Item'
  end
  
  def get_all_syncable_records
    # Get vehicles from company or location
    scope = company.vehicles.where(is_deleted: [false, nil])
    
    # Filter by location if needed
    scope = scope.where(location_id: location.id) if location.present?
    
    scope
  end
  
  def get_records_by_ids(ids)
    company.vehicles.where(id: ids)
  end
  
  def transform_to_quickbooks(vehicle, config)
    # Map vehicle to QuickBooks Item format
    {
      Name: generate_item_name(vehicle),
      Description: vehicle.description || "#{vehicle.make} #{vehicle.model} #{vehicle.year}",
      Type: config[:track_quantity] ? 'Inventory' : 'NonInventory',
      IncomeAccountRef: config[:default_account] ? { value: config[:default_account] } : nil,
      AssetAccountRef: config[:track_quantity] ? get_or_create_asset_account : nil,
      InvStartDate: vehicle.in_stock_date&.iso8601,
      QtyOnHand: config[:track_quantity] ? 1 : nil,
      UnitPrice: vehicle.price || 0,
      PurchaseCost: vehicle.cost || 0,
      TrackQtyOnHand: config[:track_quantity] || false,
      Active: vehicle.status != 'sold',
      # Custom fields for tracking
      CustomField: [
        {
          DefinitionId: '1',
          Name: 'VIN',
          Type: 'StringType',
          StringValue: vehicle.vin
        },
        {
          DefinitionId: '2',
          Name: 'Stock Number',
          Type: 'StringType',
          StringValue: vehicle.stock_number
        }
      ].compact
    }.compact
  end
  
  def find_by_quickbooks_id(qb_id)
    company.vehicles.find_by(quickbooks_id: qb_id)
  end
  
  def create_from_quickbooks(qb_item, config)
    # Extract data from QuickBooks Item
    vehicle_data = {
      company_id: company.id,
      location_id: location&.id,
      quickbooks_id: qb_item['Id'],
      stock_number: extract_custom_field(qb_item, 'Stock Number'),
      vin: extract_custom_field(qb_item, 'VIN'),
      price: qb_item['UnitPrice'],
      cost: qb_item['PurchaseCost'],
      description: qb_item['Description'],
      status: qb_item['Active'] ? 'available' : 'sold',
      quickbooks_synced_at: Time.current
    }
    
    # Parse make/model/year from description or name
    name_parts = parse_vehicle_name(qb_item['Name'])
    vehicle_data.merge!(name_parts)
    
    company.vehicles.create!(vehicle_data)
  end
  
  def update_from_quickbooks(vehicle, qb_item, config)
    vehicle.update!(
      price: qb_item['UnitPrice'],
      cost: qb_item['PurchaseCost'],
      description: qb_item['Description'],
      status: qb_item['Active'] ? 'available' : 'sold',
      quickbooks_synced_at: Time.current
    )
  end
  
  private
  
  def generate_item_name(vehicle)
    # QuickBooks Item names must be unique
    # Format: "YEAR MAKE MODEL - STOCK#"
    parts = [
      vehicle.year,
      vehicle.make,
      vehicle.model,
      vehicle.stock_number ? "- #{vehicle.stock_number}" : nil
    ].compact
    
    parts.join(' ').truncate(100)
  end
  
  def get_or_create_asset_account
    # Get or create "Inventory Asset" account in QuickBooks
    # This is required for Inventory type items
    
    # Try to find existing account
    accounts = @api.search_entities('Account', { 
      AccountType: 'Other Current Asset',
      Name: 'Inventory Asset'
    })
    
    if accounts.dig('QueryResponse', 'Account', 0)
      return { value: accounts['QueryResponse']['Account'][0]['Id'] }
    end
    
    # Create new account
    account_data = {
      Name: 'Inventory Asset',
      AccountType: 'Other Current Asset',
      AccountSubType: 'Inventory'
    }
    
    response = @api.create_entity('Account', account_data)
    { value: response.dig('Account', 'Id') }
    
  rescue => e
    Rails.logger.error "Failed to create Inventory Asset account: #{e.message}"
    nil
  end
  
  def extract_custom_field(qb_item, field_name)
    custom_fields = qb_item['CustomField'] || []
    field = custom_fields.find { |f| f['Name'] == field_name }
    field&.dig('StringValue')
  end
  
  def parse_vehicle_name(name)
    # Try to extract year, make, model from name
    # Example: "2022 Ford F-150 - ABC123"
    parts = name.split('-').first.strip.split(' ')
    
    {
      year: parts[0]&.to_i,
      make: parts[1],
      model: parts[2..-1]&.join(' ')
    }
  end
end
