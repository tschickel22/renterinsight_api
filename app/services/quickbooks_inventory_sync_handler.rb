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
    
    # IMPORTANT: Don't push vehicles that were just imported from QB
    # Only push if: (1) No quickbooks_id (new record) OR (2) Has local changes after sync
    scope = scope.where(
      'quickbooks_id IS NULL OR updated_at > quickbooks_synced_at OR quickbooks_synced_at IS NULL'
    )
    
    scope
  end
  
  def get_records_by_ids(ids)
    company.vehicles.where(id: ids)
  end
  
  def transform_to_quickbooks(vehicle, config)
    # Base item data
    data = {
      Name: generate_item_name(vehicle),
      Description: vehicle.description || "#{vehicle.make} #{vehicle.model} #{vehicle.year}",
      Type: config[:track_quantity] ? 'Inventory' : 'NonInventory',
      IncomeAccountRef: get_or_create_income_account,
      AssetAccountRef: config[:track_quantity] ? get_or_create_asset_account : nil,
      ExpenseAccountRef: config[:track_quantity] ? get_or_create_cogs_account : nil,  # CRITICAL: Required for Inventory
      QtyOnHand: config[:track_quantity] ? 1 : nil,
      UnitPrice: vehicle.sale_price || vehicle.cost || 0,
      PurchaseCost: vehicle.cost || 0,
      TrackQtyOnHand: config[:track_quantity] || false,
      Active: vehicle.status != 'sold'
    }.compact
    
    # CRITICAL: For Inventory items, QuickBooks REQUIRES InvStartDate
    # If we don't have date_in_stock, use current date
    if config[:track_quantity] && data[:Type] == 'Inventory'
      data[:InvStartDate] = (vehicle.date_in_stock || Date.today).strftime('%Y-%m-%d')
    end
    
    # DEBUG: Log what we're sending to QB
    Rails.logger.info "[QB Sync] Sending to QB for vehicle ##{vehicle.id}: #{data.inspect}"
    
    # For updates, include Id and fetch SyncToken from QB
    if vehicle.quickbooks_id.present?
      data[:Id] = vehicle.quickbooks_id
      
      # Fetch current item to get SyncToken
      begin
        qb_item = @api.get_entity('item', vehicle.quickbooks_id)
        data[:SyncToken] = qb_item['Item']['SyncToken']
      rescue => e
        Rails.logger.error "[QB Sync] Failed to fetch item #{vehicle.quickbooks_id}: #{e.message}"
        raise "Cannot update QB item without SyncToken: #{e.message}"
      end
    end
    
    data
  end
  
  def find_by_quickbooks_id(qb_id)
    company.vehicles.find_by(quickbooks_id: qb_id)
  end
  
  def create_from_quickbooks(qb_item, config)
    # Extract data from QuickBooks Item
    # Parse make/model/year from description or name
    name_parts = parse_vehicle_name(qb_item['Name'])
    
    vehicle_data = {
      company_id: company.id,
      location_id: location&.id,
      quickbooks_id: qb_item['Id'],
      stock_number: extract_custom_field(qb_item, 'Stock Number') || "QB-#{qb_item['Id']}",
      vin: extract_custom_field(qb_item, 'VIN') || "QB-IMPORTED-#{qb_item['Id']}",
      sale_price: qb_item['UnitPrice'] || 0,
      cost: qb_item['PurchaseCost'] || 0,
      description: qb_item['Description'].presence || "Imported from QuickBooks",
      status: qb_item['Active'] ? 'available' : 'sold',
      make: name_parts[:make].presence || 'QuickBooks',
      model: name_parts[:model].presence || 'Imported Item',
      year: (name_parts[:year] && name_parts[:year] > 1900) ? name_parts[:year] : 2024,
      listing_type: 'rv',
      quickbooks_synced_at: Time.current
    }
    
    Rails.logger.info "[QB Sync] Creating vehicle with data: #{vehicle_data.inspect}"
    
    company.vehicles.create!(vehicle_data)
  end
  
  def update_from_quickbooks(vehicle, qb_item, config)
    # Use update_columns to avoid triggering updated_at change
    # This prevents the sync filter from thinking there are local changes
    vehicle.update_columns(
      sale_price: qb_item['UnitPrice'],
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
  
  def get_or_create_income_account
    # Get or create "Sales" income account in QuickBooks
    # CRITICAL: For Inventory items, must use SalesOfProductIncome subtype
    
    Rails.logger.info "[QB Sync] Looking for Income account suitable for Inventory..."
    
    # First, try to find existing Income account with correct subtype for products
    begin
      result = @api.query("SELECT * FROM Account WHERE AccountType = 'Income' MAXRESULTS 50")
      accounts = result.dig('QueryResponse', 'Account') || []
      
      if accounts.any?
        # CRITICAL: Look for SalesOfProductIncome or similar product sales accounts
        # Exclude "Billable Expense Income" - wrong type for inventory!
        product_account = accounts.find do |a|
          subtype = a['AccountSubType']
          # Check for product sales related subtypes
          subtype && (subtype.include?('Product') || subtype.include?('Sales'))
        end
        
        if product_account
          Rails.logger.info "[QB Sync] Using existing Income account: #{product_account['Name']} (ID: #{product_account['Id']}, SubType: #{product_account['AccountSubType']})"
          return { value: product_account['Id'] }
        else
          # If no product sales account exists, use first non-expense Income account
          fallback = accounts.find { |a| !a['Name'].include?('Expense') && !a['Name'].include?('Billable') }
          
          if fallback
            Rails.logger.warn "[QB Sync] Using fallback Income account (not ideal): #{fallback['Name']} (ID: #{fallback['Id']}, SubType: #{fallback['AccountSubType']})"
            return { value: fallback['Id'] }
          end
        end
      end
    rescue => e
      Rails.logger.warn "[QB Sync] Failed to query Income accounts: #{e.message}"
    end
    
    # If no suitable account exists, create one with correct subtype
    begin
      Rails.logger.info "[QB Sync] Creating new Income account: Sales of Product Income"
      
      account_data = {
        Name: 'Sales of Product Income',
        AccountType: 'Income',
        AccountSubType: 'SalesOfProductIncome'  # CRITICAL: Must be this subtype for Inventory
      }
      
      response = @api.create_entity('account', account_data)
      account_id = response.dig('Account', 'Id')
      
      Rails.logger.info "[QB Sync] Created Income account with ID: #{account_id}"
      return { value: account_id }
      
    rescue => e
      Rails.logger.error "[QB Sync] Failed to create Income account: #{e.message}"
      raise "Cannot create Inventory Item without proper Income account: #{e.message}"
    end
  end
  
  def get_or_create_asset_account
    # Get or create "Inventory Asset" account in QuickBooks
    # CRITICAL: Must be AccountType 'Other Current Asset' with SubType 'Inventory'
    
    Rails.logger.info "[QB Sync] Looking for Inventory Asset account..."
    
    # Query the specific account we've been using to see what's wrong
    begin
      existing = @api.get_entity('account', '81')
      if existing && existing['Account']
        account = existing['Account']
        Rails.logger.error "[QB Sync] Account 81 details: Name=#{account['Name']}, Type=#{account['AccountType']}, SubType=#{account['AccountSubType']}"
      end
    rescue => e
      Rails.logger.warn "[QB Sync] Could not fetch account 81: #{e.message}"
    end
    
    # Try to find existing Inventory Asset account with CORRECT subtype
    begin
      result = @api.query("SELECT * FROM Account WHERE AccountType = 'Other Current Asset' MAXRESULTS 50")
      accounts = result.dig('QueryResponse', 'Account') || []
      
      Rails.logger.info "[QB Sync] Found #{accounts.count} Other Current Asset accounts"
      
      if accounts.any?
        # CRITICAL: Must have AccountSubType = 'Inventory' (not just name containing "inventory")
        inventory_account = accounts.find { |a| a['AccountSubType'] == 'Inventory' }
        
        if inventory_account
          Rails.logger.info "[QB Sync] Using Inventory Asset account: #{inventory_account['Name']} (ID: #{inventory_account['Id']}, SubType: #{inventory_account['AccountSubType']})"
          return { value: inventory_account['Id'] }
        else
          # Log what subtypes we found
          subtypes = accounts.map { |a| "#{a['Name']}: #{a['AccountSubType']}" }.join(', ')
          Rails.logger.warn "[QB Sync] No account with SubType='Inventory'. Found: #{subtypes}"
        end
      end
    rescue => e
      Rails.logger.warn "[QB Sync] Failed to query Asset accounts: #{e.message}"
    end
    
    # If no suitable account exists, create one with correct subtype
    begin
      Rails.logger.info "[QB Sync] Creating new Inventory Asset account with SubType='Inventory'"
      
      account_data = {
        Name: 'Inventory Asset',
        AccountType: 'Other Current Asset',
        AccountSubType: 'Inventory'  # CRITICAL: Must be exactly 'Inventory'
      }
      
      response = @api.create_entity('account', account_data)
      account = response['Account']
      account_id = account['Id']
      
      Rails.logger.info "[QB Sync] Created Inventory Asset account: ID=#{account_id}, SubType=#{account['AccountSubType']}"
      return { value: account_id }
      
    rescue => e
      Rails.logger.error "[QB Sync] Failed to create Inventory Asset account: #{e.message}"
      raise "Cannot create Inventory Item without proper Asset account: #{e.message}"
    end
  end
  
  def get_or_create_cogs_account
    # Get or create "Cost of Goods Sold" expense account in QuickBooks
    # CRITICAL: Required for Inventory items to track cost when sold
    
    Rails.logger.info "[QB Sync] Looking for COGS (Cost of Goods Sold) account..."
    
    # Try to find existing COGS account
    begin
      result = @api.query("SELECT * FROM Account WHERE AccountType = 'Cost of Goods Sold' MAXRESULTS 50")
      accounts = result.dig('QueryResponse', 'Account') || []
      
      Rails.logger.info "[QB Sync] Found #{accounts.count} Cost of Goods Sold accounts"
      
      if accounts.any?
        # Use first COGS account (most companies only have one)
        cogs_account = accounts.first
        
        Rails.logger.info "[QB Sync] Using COGS account: #{cogs_account['Name']} (ID: #{cogs_account['Id']}, SubType: #{cogs_account['AccountSubType']})"
        return { value: cogs_account['Id'] }
      end
    rescue => e
      Rails.logger.warn "[QB Sync] Failed to query COGS accounts: #{e.message}"
    end
    
    # If no COGS account exists, create one
    begin
      Rails.logger.info "[QB Sync] Creating new COGS account"
      
      account_data = {
        Name: 'Cost of Goods Sold',
        AccountType: 'Cost of Goods Sold',
        AccountSubType: 'SuppliesMaterialsCogs'  # Standard COGS subtype
      }
      
      response = @api.create_entity('account', account_data)
      account = response['Account']
      account_id = account['Id']
      
      Rails.logger.info "[QB Sync] Created COGS account: ID=#{account_id}, SubType=#{account['AccountSubType']}"
      return { value: account_id }
      
    rescue => e
      Rails.logger.error "[QB Sync] Failed to create COGS account: #{e.message}"
      raise "Cannot create Inventory Item without COGS account: #{e.message}"
    end
  end
  
  def extract_custom_field(qb_item, field_name)
    custom_fields = qb_item['CustomField'] || []
    field = custom_fields.find { |f| f['Name'] == field_name }
    field&.dig('StringValue')
  end
  
  def parse_vehicle_name(name)
    # Try to extract year, make, model from name
    # Example: "2022 Ford F-150 - ABC123"
    Rails.logger.info "[QB Sync] Parsing vehicle name: #{name.inspect}"
    
    parts = name.split('-').first.strip.split(' ')
    year_candidate = parts[0]&.to_i
    
    parsed = {
      year: (year_candidate && year_candidate > 1900) ? year_candidate : nil,
      make: parts[1],
      model: parts[2..-1]&.join(' ')
    }
    
    Rails.logger.info "[QB Sync] Parsed result: #{parsed.inspect}"
    parsed
  end
end
