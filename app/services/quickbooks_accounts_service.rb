# frozen_string_literal: true

# QuickBooks Accounts Service
# Handles fetching and mapping of QuickBooks Chart of Accounts

class QuickbooksAccountsService
  attr_reader :entity, :api_service
  
  def initialize(entity)
    @entity = entity
    @api_service = QuickbooksApiService.new(entity)
  end
  
  # Fetch Chart of Accounts from QuickBooks
  def fetch_chart_of_accounts(force_refresh: false)
    cache_key = "qb_accounts_#{entity.id}_#{entity.class.name}"
    
    # Return cached if available and not forcing refresh
    unless force_refresh
      cached = Rails.cache.read(cache_key)
      return cached if cached.present?
    end
    
    # Fetch from QuickBooks
    query = "SELECT * FROM Account WHERE Active = true"
    response = api_service.query(query)
    
    accounts = response['QueryResponse']&.dig('Account') || []
    
    # Transform accounts to frontend format
    transformed_accounts = accounts.map do |account|
      {
        id: account['Id'],
        name: account['Name'],
        type: account['AccountType'],
        subType: account['AccountSubType']
      }
    end
    
    # Organize by type
    organized_accounts = {
      income: transformed_accounts.select { |a| a[:type] == 'Income' },
      expense: transformed_accounts.select { |a| a[:type] == 'Expense' },
      asset: transformed_accounts.select { |a| ['Bank', 'Other Current Asset', 'Fixed Asset', 'Other Asset'].include?(a[:type]) },
      liability: transformed_accounts.select { |a| ['Credit Card', 'Other Current Liability', 'Long Term Liability'].include?(a[:type]) },
      equity: transformed_accounts.select { |a| a[:type] == 'Equity' },
      cost_of_goods_sold: transformed_accounts.select { |a| a[:type] == 'Cost of Goods Sold' }
    }
    
    # Cache for 1 hour
    Rails.cache.write(cache_key, organized_accounts, expires_in: 1.hour)
    
    organized_accounts
  end
  
  # Get account mappings from settings
  def get_account_mappings
    settings = entity.resolved_quickbooks_settings || {}
    settings[:account_mappings] || default_account_mappings
  end
  
  # Update account mappings
  def update_account_mappings(mappings)
    current_settings = entity.resolved_quickbooks_settings.deep_dup || {}
    current_settings[:account_mappings] = mappings.deep_symbolize_keys
    entity.update_quickbooks_settings!(current_settings)
  end
  
  # Get account by ID from QB
  def get_account_by_id(account_id)
    response = api_service.get("account/#{account_id}")
    response['Account']
  end
  
  private
  
  def default_account_mappings
    {
      income: {
        # Rental Income
        rent: nil,
        lot_rent: nil,
        late_fees: nil,
        application_fees: nil,
        other_charges: nil,
        # Sales & Service Income
        inventory_sales: nil,
        parts_sales: nil,
        service_labor: nil,
        warranty_revenue: nil,
        finance_charges: nil,
        documentation_fees: nil
      },
      cogs: {
        inventory_cogs: nil,
        parts_cogs: nil,
        warranty_expense: nil
      },
      assets_liabilities: {
        loans_receivable: nil,
        security_deposits: nil,
        operating_cash: nil
      }
    }
  end
end
