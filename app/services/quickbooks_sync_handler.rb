# frozen_string_literal: true

# Base Sync Handler for QuickBooks entities
# Provides common functionality for all entity-specific handlers

class QuickbooksSyncHandler
  attr_reader :entity, :api
  
  def initialize(entity, api)
    @entity = entity # Company or Location
    @api = api
  end
  
  # Override in subclasses
  def qb_entity_type
    raise NotImplementedError
  end
  
  # Override in subclasses
  def get_all_syncable_records
    raise NotImplementedError
  end
  
  # Override in subclasses
  def get_records_by_ids(ids)
    raise NotImplementedError
  end
  
  # Batch load records by QuickBooks IDs (performance optimization)
  # Subclasses can override for custom logic
  def get_records_by_quickbooks_ids(qb_ids)
    # Default implementation - override in subclasses for specific models
    []
  end
  
  # Override in subclasses
  def transform_to_quickbooks(record, config)
    raise NotImplementedError
  end
  
  # Override in subclasses
  def find_by_quickbooks_id(qb_id)
    raise NotImplementedError
  end
  
  # Override in subclasses
  def create_from_quickbooks(qb_entity, config)
    raise NotImplementedError
  end
  
  # Override in subclasses
  def update_from_quickbooks(record, qb_entity, config)
    raise NotImplementedError
  end
  
  def save_quickbooks_id(record, qb_id)
    record.update_columns(
      quickbooks_id: qb_id,
      quickbooks_synced_at: Time.current
    )
  end
  
  protected
  
  def company
    @entity.is_a?(Location) ? @entity.company : @entity
  end
  
  def location
    @entity.is_a?(Location) ? @entity : nil
  end
  
  # Get account mappings from settings
  def account_mappings
    @account_mappings ||= begin
      accounts_service = QuickbooksAccountsService.new(@entity)
      accounts_service.get_account_mappings
    end
  end
  
  # Get QB account ID from mapping, with fallback to hardcoded lookup
  def get_account_from_mapping(category, field, fallback_query = nil)
    # Try to get from mapping first
    mapping_value = account_mappings.dig(category, field)
    
    if mapping_value.present?
      Rails.logger.info "[QB Sync] Using mapped #{category}.#{field} account: #{mapping_value}"
      return { value: mapping_value }
    end
    
    # If no mapping and fallback query provided, try to find account
    if fallback_query.present?
      Rails.logger.warn "[QB Sync] No mapping for #{category}.#{field}, using fallback query"
      begin
        result = @api.query(fallback_query)
        accounts = result.dig('QueryResponse', 'Account') || []
        
        if accounts.any?
          account = accounts.first
          Rails.logger.info "[QB Sync] Found fallback account: #{account['Name']} (ID: #{account['Id']})"
          return { value: account['Id'] }
        end
      rescue => e
        Rails.logger.error "[QB Sync] Fallback query failed: #{e.message}"
      end
    end
    
    # If we get here, account is not mapped and fallback failed
    Rails.logger.error "[QB Sync] CRITICAL: No account mapping for #{category}.#{field} and fallback failed"
    raise "Account mapping required: Please map #{category}.#{field} in QuickBooks settings"
  end
end
