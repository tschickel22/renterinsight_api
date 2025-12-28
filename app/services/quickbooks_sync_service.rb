# frozen_string_literal: true

# QuickBooks Sync Service
# Main orchestrator for syncing data between Renter Insight and QuickBooks
# Handles entity mapping, conflict resolution, and sync logging

class QuickbooksSyncService
  attr_reader :entity, :api, :settings
  
  def initialize(entity)
    @entity = entity # Company or Location
    @api = QuickbooksApiService.new(entity)
    @settings = entity.resolved_quickbooks_settings || {}
  end
  
  # Sync specific entity type (e.g., 'inventory', 'customers')
  def sync_entity_type(entity_type, direction: nil, entity_ids: nil)
    # Get entity settings
    entity_config = @settings.dig(:entities, entity_type.to_sym) || {}
    
    # Check if sync is enabled
    unless entity_config[:enabled]
      return { success: false, message: "Sync disabled for #{entity_type}" }
    end
    
    # Use configured direction or override
    sync_direction = direction || entity_config[:sync_direction] || 'to_qb'
    
    # Create sync log
    log = create_sync_log(entity_type, sync_direction)
    
    begin
      result = case sync_direction
      when 'to_qb'
        sync_to_quickbooks(entity_type, entity_ids, entity_config)
      when 'from_qb'
        sync_from_quickbooks(entity_type, entity_config)
      when 'bidirectional'
        sync_bidirectional(entity_type, entity_ids, entity_config)
      else
        raise "Unknown sync direction: #{sync_direction}"
      end
      
      log.mark_success!(result)
      
      # Update entity's last sync timestamp
      @entity.update_column(:quickbooks_last_sync_at, Time.current)
      
      { success: true, log: log, result: result }
      
    rescue => e
      Rails.logger.error "QuickBooks sync error (#{entity_type}): #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      log.mark_error!(e.message)
      
      { success: false, log: log, error: e.message }
    end
  end
  
  # Sync all enabled entities
  def sync_all_entities(direction: nil)
    results = {}
    
    ENTITY_TYPES.each do |entity_type|
      result = sync_entity_type(entity_type, direction: direction)
      results[entity_type] = result
    end
    
    results
  end
  
  private
  
  ENTITY_TYPES = %w[inventory customers invoices payments vendors purchases]
  
  def sync_to_quickbooks(entity_type, entity_ids, config)
    handler = get_sync_handler(entity_type)
    
    # Get records to sync
    records = if entity_ids.present?
      handler.get_records_by_ids(entity_ids)
    else
      handler.get_all_syncable_records
    end
    
    synced = 0
    skipped = 0
    errors = []
    
    records.each do |record|
      begin
        # Check if record should be synced (filtering rules)
        unless should_sync_record?(record, config)
          skipped += 1
          next
        end
        
        # Transform to QuickBooks format
        qb_data = handler.transform_to_quickbooks(record, config)
        
        # Check if exists in QuickBooks
        if record.quickbooks_id.present?
          # Update existing
          @api.update_entity(handler.qb_entity_type, record.quickbooks_id, qb_data)
        else
          # Create new
          response = @api.create_entity(handler.qb_entity_type, qb_data)
          qb_id = response.dig(handler.qb_entity_type, 'Id')
          
          # Save QuickBooks ID back to our record
          handler.save_quickbooks_id(record, qb_id)
        end
        
        synced += 1
        
      rescue => e
        errors << { record_id: record.id, error: e.message }
        Rails.logger.error "Failed to sync #{entity_type} ##{record.id}: #{e.message}"
      end
    end
    
    {
      synced: synced,
      skipped: skipped,
      errors: errors,
      total: records.count
    }
  end
  
  def sync_from_quickbooks(entity_type, config)
    handler = get_sync_handler(entity_type)
    
    # Get all entities from QuickBooks
    qb_entities = @api.get_all_entities(handler.qb_entity_type)
    
    synced = 0
    skipped = 0
    errors = []
    
    qb_entities.each do |qb_entity|
      begin
        qb_id = qb_entity['Id']
        
        # Find existing record or create new
        record = handler.find_by_quickbooks_id(qb_id)
        
        if record
          # Update existing - check for conflicts
          if record_has_local_changes?(record)
            handle_conflict(record, qb_entity, config)
          else
            handler.update_from_quickbooks(record, qb_entity, config)
          end
        else
          # Create new
          handler.create_from_quickbooks(qb_entity, config)
        end
        
        synced += 1
        
      rescue => e
        errors << { qb_id: qb_entity['Id'], error: e.message }
        Rails.logger.error "Failed to import #{entity_type} from QB: #{e.message}"
      end
    end
    
    {
      synced: synced,
      skipped: skipped,
      errors: errors,
      total: qb_entities.count
    }
  end
  
  def sync_bidirectional(entity_type, entity_ids, config)
    # First sync TO QuickBooks
    to_qb_result = sync_to_quickbooks(entity_type, entity_ids, config)
    
    # Then sync FROM QuickBooks
    from_qb_result = sync_from_quickbooks(entity_type, config)
    
    {
      to_qb: to_qb_result,
      from_qb: from_qb_result
    }
  end
  
  def get_sync_handler(entity_type)
    case entity_type.to_s
    when 'inventory'
      QuickbooksInventorySyncHandler.new(@entity, @api)
    when 'customers'
      QuickbooksCustomerSyncHandler.new(@entity, @api)
    when 'invoices'
      QuickbooksInvoiceSyncHandler.new(@entity, @api)
    when 'payments'
      QuickbooksPaymentSyncHandler.new(@entity, @api)
    when 'vendors'
      QuickbooksVendorSyncHandler.new(@entity, @api)
    when 'purchases'
      QuickbooksPurchaseSyncHandler.new(@entity, @api)
    else
      raise "Unknown entity type: #{entity_type}"
    end
  end
  
  def should_sync_record?(record, config)
    # TODO: Implement filtering rules from config
    # For now, sync all non-deleted records
    !record.is_deleted
  end
  
  def record_has_local_changes?(record)
    # Check if record was modified after last sync
    return false unless record.respond_to?(:quickbooks_synced_at)
    
    record.updated_at > record.quickbooks_synced_at if record.quickbooks_synced_at.present?
  end
  
  def handle_conflict(record, qb_entity, config)
    strategy = get_conflict_strategy(record.class.name.underscore.pluralize, config)
    
    case strategy
    when 'ri_wins'
      # Keep our version, overwrite QB
      handler = get_sync_handler(record.class.name.underscore.pluralize)
      qb_data = handler.transform_to_quickbooks(record, config)
      @api.update_entity(handler.qb_entity_type, record.quickbooks_id, qb_data)
      
    when 'qb_wins'
      # Keep QB version, overwrite ours
      handler = get_sync_handler(record.class.name.underscore.pluralize)
      handler.update_from_quickbooks(record, qb_entity, config)
      
    when 'most_recent'
      # Compare timestamps
      qb_updated = Time.parse(qb_entity['MetaData']['LastUpdatedTime'])
      
      if record.updated_at > qb_updated
        # Our version is newer
        handler = get_sync_handler(record.class.name.underscore.pluralize)
        qb_data = handler.transform_to_quickbooks(record, config)
        @api.update_entity(handler.qb_entity_type, record.quickbooks_id, qb_data)
      else
        # QB version is newer
        handler = get_sync_handler(record.class.name.underscore.pluralize)
        handler.update_from_quickbooks(record, qb_entity, config)
      end
      
    when 'manual_review'
      # Create conflict record for manual resolution
      create_conflict_record(record, qb_entity)
      
    else
      Rails.logger.warn "Unknown conflict strategy: #{strategy}, using ri_wins"
      handler = get_sync_handler(record.class.name.underscore.pluralize)
      qb_data = handler.transform_to_quickbooks(record, config)
      @api.update_entity(handler.qb_entity_type, record.quickbooks_id, qb_data)
    end
  end
  
  def get_conflict_strategy(entity_type, config)
    # Check for entity-specific override
    conflict_settings = @settings[:conflict_resolution] || {}
    entity_overrides = conflict_settings[:entity_overrides] || {}
    
    entity_overrides[entity_type.to_sym] || conflict_settings[:default_strategy] || 'ri_wins'
  end
  
  def create_conflict_record(record, qb_entity)
    # TODO: Create QuickbooksConflict model to store conflicts for manual review
    Rails.logger.info "Conflict detected for #{record.class.name} ##{record.id}"
  end
  
  def create_sync_log(entity_type, sync_direction)
    company = @entity.is_a?(Location) ? @entity.company : @entity
    location = @entity.is_a?(Location) ? @entity : nil
    
    company.quickbooks_sync_logs.create!(
      location: location,
      operation: 'entity_sync',
      entity_type: entity_type,
      sync_direction: sync_direction,
      status: 'pending',
      started_at: Time.current
    )
  end
end
