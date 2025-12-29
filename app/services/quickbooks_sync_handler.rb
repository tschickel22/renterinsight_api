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
end
