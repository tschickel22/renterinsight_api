# frozen_string_literal: true

# QuickBooks Sync Service
# Main orchestrator for syncing data between Renter Insight and QuickBooks
# Handles entity mapping, conflict resolution, and sync logging

class QuickbooksSyncService
  attr_reader :entity, :api, :settings

  # Advisory-lock namespace for whole-entity sync operations. Distinct from
  # accounting number-generator and token-refresh namespaces.
  SYNC_LOCK_NAMESPACE = 0x1_2E_00_5C.freeze

  def initialize(entity)
    @entity = entity # Company or Location
    @api = QuickbooksApiService.new(entity)
    @settings = entity.resolved_quickbooks_settings || {}
  end

  # Wrap a sync operation in a per-entity advisory lock so a manual sync
  # can't race a scheduled sync on the same company/location — concurrent
  # runs could otherwise write conflicting SyncTokens or double-import.
  # Waits for the lock (no timeout) because the caller is a background job
  # and starving one run is worse than delaying it briefly.
  def with_sync_lock(&block)
    ApplicationRecord.transaction do
      self.class.connection.execute(
        ActiveRecord::Base.sanitize_sql_array([
          'SELECT pg_advisory_xact_lock(?, ?)',
          SYNC_LOCK_NAMESPACE,
          @entity.id
        ])
      )
      block.call
    end
  end

  def self.connection
    ActiveRecord::Base.connection
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
      result = with_sync_lock do
        case sync_direction
        when 'to_qb'
          sync_to_quickbooks(entity_type, entity_ids, entity_config)
        when 'from_qb'
          sync_from_quickbooks(entity_type, entity_config)
        when 'bidirectional'
          sync_bidirectional(entity_type, entity_ids, entity_config)
        else
          raise "Unknown sync direction: #{sync_direction}"
        end
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
  
  # Incremental sync - only syncs changed/new records for enabled entities
  # This is the main method used by AutoSyncJob for scheduled syncs
  def incremental_sync(since: nil)
    results = {}
    total_synced = 0
    total_errors = 0
    
    # Use last sync time if 'since' not provided
    since ||= @entity.quickbooks_last_sync_at
    
    Rails.logger.info "[QB Incremental Sync] Starting for #{@entity.class.name} ##{@entity.id}"
    Rails.logger.info "[QB Incremental Sync] Only syncing records changed since: #{since}" if since.present?
    
    begin
      ENTITY_TYPES.each do |entity_type|
        entity_config = @settings.dig(:entities, entity_type.to_sym) || {}
        
        # Skip if not enabled
        unless entity_config[:enabled]
          Rails.logger.debug "[QB Incremental Sync] Skipping #{entity_type} (disabled)"
          next
        end
        
        # For incremental sync, only sync records changed since last sync
        # Pass 'since' parameter to sync handler for date-based filtering
        result = sync_entity_type_incremental(entity_type, since, entity_config)
        results[entity_type] = result
        
        if result[:success]
          synced = result.dig(:result, :to_qb, :synced) || result.dig(:result, :synced) || 0
          errors = result.dig(:result, :to_qb, :errors) || result.dig(:result, :errors) || []
          total_synced += synced
          total_errors += errors.count
          
          Rails.logger.info "[QB Incremental Sync] #{entity_type}: #{synced} synced, #{errors.count} errors"
        else
          Rails.logger.error "[QB Incremental Sync] #{entity_type} failed: #{result[:error]}"
          total_errors += 1
        end
      end
      
      # CRITICAL: Always update last_sync timestamp even if no entities were enabled
      # This ensures the status cards show current sync time
      @entity.update_column(:quickbooks_last_sync_at, Time.current)
      
      Rails.logger.info "[QB Incremental Sync] Complete: #{total_synced} records synced, #{total_errors} errors"
      Rails.logger.info "[QB Incremental Sync] Updated last_sync_at to #{@entity.quickbooks_last_sync_at}"
      
      { 
        success: true, 
        message: "Synced #{total_synced} records across #{results.keys.count} entity types",
        results: results,
        summary: {
          total_synced: total_synced,
          total_errors: total_errors,
          entity_count: results.keys.count
        }
      }
    rescue => e
      Rails.logger.error "[QB Incremental Sync] Fatal error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      # Still update timestamp even on error so UI knows sync was attempted
      @entity.update_column(:quickbooks_last_sync_at, Time.current)
      
      { success: false, error: e.message }
    end
  end
  
  # Incremental sync for specific entity type - only syncs changes since 'since' timestamp
  def sync_entity_type_incremental(entity_type, since, config)
    log = create_sync_log(entity_type, config[:sync_direction] || 'bidirectional')
    
    begin
      # For incremental sync, we want to:
      # 1. Push NEW local records to QB (quickbooks_id IS NULL)
      # 2. Push MODIFIED local records to QB (updated_at > quickbooks_synced_at)
      # 3. Pull MODIFIED QB records (LastUpdatedTime > since)
      
      sync_direction = config[:sync_direction] || 'to_qb'
      
      result = case sync_direction
      when 'to_qb'
        sync_to_quickbooks_incremental(entity_type, since, config)
      when 'from_qb'
        sync_from_quickbooks_incremental(entity_type, since, config)
      when 'bidirectional'
        {
          to_qb: sync_to_quickbooks_incremental(entity_type, since, config),
          from_qb: sync_from_quickbooks_incremental(entity_type, since, config)
        }
      else
        raise "Unknown sync direction: #{sync_direction}"
      end
      
      log.mark_success!(result)
      
      # Update entity's last sync timestamp
      @entity.update_column(:quickbooks_last_sync_at, Time.current)
      
      { success: true, log: log, result: result }
      
    rescue => e
      Rails.logger.error "QuickBooks incremental sync error (#{entity_type}): #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      log.mark_error!(e.message)
      
      { success: false, log: log, error: e.message }
    end
  end
  
  private
  
  # 'purchases' is intentionally out — the handler targets a nonexistent
  # Purchase model rather than the real PurchaseOrder. Rewrite handler
  # (fields: po_number/order_date/total_amount, associations: supplier,
  # purchase_order_lines) before re-adding it here.
  ENTITY_TYPES = %w[inventory customers invoices payments vendors]
  
  # Sync TO QuickBooks - only records that are new or modified since 'since'
  def sync_to_quickbooks_incremental(entity_type, since, config)
    # For now, fall back to regular sync_to_quickbooks with nil entity_ids
    # This will use should_sync_record? to filter
    # TODO: Implement handler.get_changed_records_since(since) for true incremental sync
    Rails.logger.info "[QB Sync TO] #{entity_type}: Incremental sync (filtering locally)"
    sync_to_quickbooks(entity_type, nil, config)
  end
  
  # Sync FROM QuickBooks — filter by QB's MetaData.LastUpdatedTime > since
  # so we don't re-fetch every entity on every tick. Falls back to a full
  # scan if `since` is nil (first sync).
  def sync_from_quickbooks_incremental(entity_type, since, config)
    Rails.logger.info "[QB Sync FROM] #{entity_type}: Incremental sync since #{since || 'beginning'}"
    sync_from_quickbooks(entity_type, config, since: since)
  end
  
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

          # Save QuickBooks ID back — refuse to persist nil since a null id
          # would let the next sync pass re-create the same record as a
          # duplicate in QB.
          if qb_id.present?
            handler.save_quickbooks_id(record, qb_id)
          else
            raise QuickbooksApiError, "QB create response missing Id for #{handler.qb_entity_type} ##{record.id}: #{response.inspect}"
          end
        end
        
        # CRITICAL: Update sync timestamp so we don't re-sync unchanged records
        record.update_column(:quickbooks_synced_at, Time.current) if record.respond_to?(:quickbooks_synced_at=)
        
        synced += 1
        
      rescue QuickbooksValidationError => e
        # Handle "Duplicate Name Exists Error" with unique name retry
        if e.message.include?('Duplicate Name Exists') && handler.respond_to?(:transform_to_quickbooks)
          retry_result = retry_with_unique_name(handler, record, config)
          if retry_result[:success]
            synced += 1
            next
          else
            errors << { record_id: record.id, error: retry_result[:error] }
            Rails.logger.error "Failed to sync #{entity_type} ##{record.id} (after retry): #{retry_result[:error]}"
          end
        else
          errors << { record_id: record.id, error: e.message }
          Rails.logger.error "Failed to sync #{entity_type} ##{record.id}: #{e.message}"
        end
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
  
  def sync_from_quickbooks(entity_type, config, since: nil)
    handler = get_sync_handler(entity_type)

    # Ask QB for only entities changed since `since` — a proper incremental
    # pull. `since` nil means first-time sync, so we scan the whole realm.
    qb_entities = @api.get_all_entities(handler.qb_entity_type, since: since)
    
    # OPTIMIZATION: Batch-load all existing records to avoid N+1 queries
    qb_ids = qb_entities.map { |e| e['Id'] }.compact
    existing_records_map = handler.get_records_by_quickbooks_ids(qb_ids).index_by(&:quickbooks_id)
    
    synced = 0
    skipped = 0
    errors = []
    
    qb_entities.each do |qb_entity|
      begin
        qb_id = qb_entity['Id']
        
        # Find existing record from batch-loaded map (1 query instead of 1000!)
        record = existing_records_map[qb_id]
        
        # Use find_or_initialize_from_quickbooks if no record found and handler supports it
        if !record && handler.respond_to?(:find_or_initialize_from_quickbooks)
          record = handler.find_or_initialize_from_quickbooks(qb_entity)
        end
        
        if record
          # Check if QB entity has changed since last sync
          if qb_entity_has_changes?(record, qb_entity)
            # Update existing - check for conflicts
            if record_has_local_changes?(record)
              handle_conflict(record, qb_entity, config)
            else
              handler.update_from_quickbooks(record, qb_entity, config)
            end
            
            # CRITICAL: Update sync timestamp so we don't re-sync this record
            record.update_column(:quickbooks_synced_at, Time.current) if record.respond_to?(:quickbooks_synced_at=)
            
            synced += 1
          else
            # No changes in QB since last sync - skip
            skipped += 1
          end
        else
          # Create new
          new_record = handler.create_from_quickbooks(qb_entity, config)
          
          # CRITICAL: Set sync timestamp on new records
          new_record.update_column(:quickbooks_synced_at, Time.current) if new_record.respond_to?(:quickbooks_synced_at=)
          
          synced += 1
        end
        
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
    # Skip deleted records
    return false if record.is_deleted
    
    # Sync if no QuickBooks ID (new record)
    return true if record.quickbooks_id.blank?
    
    # Sync if modified after last sync (edited record)
    if record.respond_to?(:quickbooks_synced_at) && record.quickbooks_synced_at.present?
      return record.updated_at > record.quickbooks_synced_at
    end
    
    # Default to not syncing if we're not sure
    false
  end
  
  def record_has_local_changes?(record)
    # Check if record was modified after last sync
    return false unless record.respond_to?(:quickbooks_synced_at)
    
    record.updated_at > record.quickbooks_synced_at if record.quickbooks_synced_at.present?
  end
  
  def qb_entity_has_changes?(record, qb_entity)
    # If record has never been synced, consider it changed
    return true unless record.respond_to?(:quickbooks_synced_at)
    return true if record.quickbooks_synced_at.blank?
    
    # Compare QB's LastUpdatedTime with our last sync time
    qb_updated_at = qb_entity.dig('MetaData', 'LastUpdatedTime')
    return true if qb_updated_at.blank? # If QB doesn't provide timestamp, sync it
    
    begin
      qb_timestamp = Time.parse(qb_updated_at)
      # QB entity changed if its LastUpdatedTime is after our last sync
      qb_timestamp > record.quickbooks_synced_at
    rescue
      # If timestamp parsing fails, sync it to be safe
      true
    end
  end
  
  # Alias for incremental sync - same logic
  alias_method :qb_entity_actually_changed?, :qb_entity_has_changes?
  
  def handle_conflict(record, qb_entity, config)
    # Map model name to entity type (Contact → customers, Vehicle → inventory, etc.)
    entity_type = model_to_entity_type(record.class.name)
    strategy = get_conflict_strategy(entity_type, config)
    
    case strategy
    when 'ri_wins'
      # Keep our version, overwrite QB
      handler = get_sync_handler(entity_type)
      qb_data = handler.transform_to_quickbooks(record, config)
      @api.update_entity(handler.qb_entity_type, record.quickbooks_id, qb_data)
      
    when 'qb_wins'
      # Keep QB version, overwrite ours
      handler = get_sync_handler(entity_type)
      handler.update_from_quickbooks(record, qb_entity, config)
      
    when 'most_recent'
      # Compare timestamps
      qb_updated = Time.parse(qb_entity['MetaData']['LastUpdatedTime'])
      
      if record.updated_at > qb_updated
        # Our version is newer
        handler = get_sync_handler(entity_type)
        qb_data = handler.transform_to_quickbooks(record, config)
        @api.update_entity(handler.qb_entity_type, record.quickbooks_id, qb_data)
      else
        # QB version is newer
        handler = get_sync_handler(entity_type)
        handler.update_from_quickbooks(record, qb_entity, config)
      end
      
    when 'manual_review'
      # Create conflict record for manual resolution
      create_conflict_record(record, qb_entity)
      
    else
      Rails.logger.warn "Unknown conflict strategy: #{strategy}, using ri_wins"
      handler = get_sync_handler(entity_type)
      qb_data = handler.transform_to_quickbooks(record, config)
      @api.update_entity(handler.qb_entity_type, record.quickbooks_id, qb_data)
    end
  end
  
  def model_to_entity_type(model_name)
    # Map model names to sync entity types
    case model_name
    when 'Contact'
      'customers'
    when 'Vehicle'
      'inventory'
    when 'Invoice'
      'invoices'
    when 'Payment'
      'payments'
    when 'Vendor'
      'vendors'
    when 'Purchase'
      'purchases'
    else
      model_name.underscore.pluralize
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

  # Retry sync with progressively more unique DisplayName
  # Attempt 1: append email (e.g., "John Smith - john@example.com")
  # Attempt 2: append record ID (e.g., "John Smith (42)")
  def retry_with_unique_name(handler, record, config)
    suffixes = [:email, :id]

    suffixes.each do |suffix|
      begin
        Rails.logger.info "[QB Sync] Retrying #{record.class.name} ##{record.id} with unique_suffix: #{suffix}"
        qb_data = handler.transform_to_quickbooks(record, config, unique_suffix: suffix)

        if record.quickbooks_id.present?
          @api.update_entity(handler.qb_entity_type, record.quickbooks_id, qb_data)
        else
          response = @api.create_entity(handler.qb_entity_type, qb_data)
          qb_id = response.dig(handler.qb_entity_type, 'Id')
          raise QuickbooksApiError, "QB create response missing Id for #{handler.qb_entity_type} ##{record.id}" if qb_id.blank?
          handler.save_quickbooks_id(record, qb_id)
        end

        record.update_column(:quickbooks_synced_at, Time.current) if record.respond_to?(:quickbooks_synced_at=)
        Rails.logger.info "[QB Sync] Retry succeeded for #{record.class.name} ##{record.id} with suffix: #{suffix}"
        return { success: true }
      rescue QuickbooksValidationError => e
        next if e.message.include?('Duplicate Name Exists')
        return { success: false, error: e.message }
      rescue => e
        return { success: false, error: e.message }
      end
    end

    { success: false, error: 'Duplicate Name Exists Error - all retry suffixes exhausted' }
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
