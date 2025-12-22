# frozen_string_literal: true

class QuickbooksSyncService
  attr_reader :entity, :api_service
  
  def initialize(entity)
    @entity = entity
    @api_service = QuickbooksApiService.new(entity)
  end
  
  def full_sync
    results = {
      vehicles: sync_vehicles,
      contacts: sync_contacts
    }
    
    entity.update!(quickbooks_last_sync_at: Time.current)
    results
  end
  
  def incremental_sync(since: nil)
    since ||= entity.quickbooks_last_sync_at || 24.hours.ago
    
    entities = ['Item', 'Customer']
    result = api_service.get_cdc(entities, since)
    
    return { success: false, error: result[:error] } unless result[:success]
    
    { success: true, message: 'CDC processing implemented' }
  end
  
  def sync_entity(entity_type, entity_id)
    case entity_type.to_s.downcase
    when 'vehicle'
      sync_single_vehicle(entity_id)
    when 'contact'
      sync_single_contact(entity_id)
    else
      { success: false, error: "Unknown entity type: #{entity_type}" }
    end
  end
  
  private
  
  def sync_vehicles
    settings = entity.resolved_quickbooks_settings[:entities][:inventory]
    return { skipped: true, reason: 'Disabled' } unless settings[:enabled]
    
    vehicles = entity.is_a?(Location) ? entity.vehicles : Company.find(entity.id).vehicles
    
    vehicles.find_each.map do |vehicle|
      sync_single_vehicle(vehicle.id)
    end
  end
  
  def sync_single_vehicle(vehicle_id)
    company = entity.is_a?(Company) ? entity : entity.company
    vehicle = company.vehicles.find(vehicle_id)
    settings = entity.resolved_quickbooks_settings[:entities][:inventory]
    
    mapping = QuickbooksSyncMapping.find_for_entity('Vehicle', vehicle.id, company.id, entity.is_a?(Location) ? entity.id : nil)
    
    item_data = {
      Name: "#{vehicle.year} #{vehicle.make} #{vehicle.model}".strip,
      Type: 'Inventory',
      TrackQtyOnHand: settings[:track_quantity],
      Active: vehicle.status != 'sold'
    }
    
    item_data[:IncomeAccountRef] = { value: settings[:default_account] } if settings[:default_account]
    item_data[:QtyOnHand] = vehicle.available? ? 1 : 0 if settings[:track_quantity]
    
    log = QuickbooksSyncLog.create!(
      company: company,
      location: entity.is_a?(Location) ? entity : nil,
      operation: mapping ? 'update' : 'create',
      entity_type: 'Vehicle',
      entity_id: vehicle.id,
      sync_direction: 'to_qb',
      status: 'pending',
      started_at: Time.current
    )
    
    begin
      result = if mapping
        api_service.update_item(mapping.quickbooks_entity_id, item_data)
      else
        api_service.create_item(item_data)
      end
      
      if result[:success]
        qb_item = result[:data]['Item']
        
        unless mapping
          mapping = QuickbooksSyncMapping.create!(
            company: company,
            location: entity.is_a?(Location) ? entity : nil,
            renter_insight_entity_type: 'Vehicle',
            renter_insight_entity_id: vehicle.id,
            quickbooks_entity_type: 'Item',
            quickbooks_entity_id: qb_item['Id'],
            sync_direction: 'bidirectional'
          )
        end
        
        mapping.mark_synced!(qb_item)
        log.mark_success!(result[:data])
        { success: true, mapping: mapping }
      else
        log.mark_error!(result[:error], result[:response])
        mapping&.mark_error!(result[:error])
        { success: false, error: result[:error] }
      end
    rescue => e
      log.mark_error!(e.message)
      mapping&.mark_error!(e.message)
      { success: false, error: e.message }
    end
  end
  
  def sync_contacts
    settings = entity.resolved_quickbooks_settings[:entities][:customers]
    return { skipped: true, reason: 'Disabled' } unless settings[:enabled]
    
    company = entity.is_a?(Company) ? entity : entity.company
    contacts = company.contacts
    
    contacts.find_each.map do |contact|
      sync_single_contact(contact.id)
    end
  end
  
  def sync_single_contact(contact_id)
    company = entity.is_a?(Company) ? entity : entity.company
    contact = company.contacts.find(contact_id)
    
    mapping = QuickbooksSyncMapping.find_for_entity('Contact', contact.id, company.id, entity.is_a?(Location) ? entity.id : nil)
    
    customer_data = {
      DisplayName: contact.full_name || "#{contact.first_name} #{contact.last_name}".strip,
      GivenName: contact.first_name,
      FamilyName: contact.last_name,
      Active: true
    }
    
    customer_data[:PrimaryEmailAddr] = { Address: contact.email } if contact.email.present?
    customer_data[:PrimaryPhone] = { FreeFormNumber: contact.phone } if contact.phone.present?
    
    log = QuickbooksSyncLog.create!(
      company: company,
      location: entity.is_a?(Location) ? entity : nil,
      operation: mapping ? 'update' : 'create',
      entity_type: 'Contact',
      entity_id: contact.id,
      sync_direction: 'to_qb',
      status: 'pending',
      started_at: Time.current
    )
    
    begin
      result = if mapping
        api_service.update_customer(mapping.quickbooks_entity_id, customer_data)
      else
        api_service.create_customer(customer_data)
      end
      
      if result[:success]
        qb_customer = result[:data]['Customer']
        
        unless mapping
          mapping = QuickbooksSyncMapping.create!(
            company: company,
            location: entity.is_a?(Location) ? entity : nil,
            renter_insight_entity_type: 'Contact',
            renter_insight_entity_id: contact.id,
            quickbooks_entity_type: 'Customer',
            quickbooks_entity_id: qb_customer['Id'],
            sync_direction: 'bidirectional'
          )
        end
        
        mapping.mark_synced!(qb_customer)
        log.mark_success!(result[:data])
        { success: true, mapping: mapping }
      else
        log.mark_error!(result[:error], result[:response])
        mapping&.mark_error!(result[:error])
        { success: false, error: result[:error] }
      end
    rescue => e
      log.mark_error!(e.message)
      mapping&.mark_error!(e.message)
      { success: false, error: e.message }
    end
  end
end
