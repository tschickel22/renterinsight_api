class Note < ApplicationRecord
  include ActivityTrackable

  belongs_to :user, optional: true
  
  validates :content, presence: true
  validates :entity_type, presence: true
  validates :entity_id, presence: true
  
  scope :for_entity, ->(type, id) { where(entity_type: type, entity_id: id) }
  scope :recent, -> { order(created_at: :desc) }

  before_save :set_created_by_name

  # ActivityTrackable overrides
  def activity_display_name
    content&.truncate(50) || 'Note'
  end

  def activity_module_name
    'general'
  end

  def activity_account_id
    case entity_type&.downcase
    when 'account' then entity_id
    when 'contact' then Contact.find_by(id: entity_id)&.account_id
    when 'deal' then Deal.find_by(id: entity_id)&.account_id
    when 'lead' then Lead.find_by(id: entity_id)&.converted_account_id
    else nil
    end
  end

  def activity_location_id
    entity = case entity_type&.downcase
             when 'lead' then Lead.find_by(id: entity_id)
             when 'contact' then Contact.find_by(id: entity_id)
             when 'account' then Account.find_by(id: entity_id)
             when 'deal' then Deal.find_by(id: entity_id)
             else nil
             end
    entity&.try(:location_id)
  end

  # Must be public - ActivityTrackable concern uses try(:company)
  def company
    case entity_type&.downcase
    when 'lead' then Lead.find_by(id: entity_id)&.company
    when 'contact' then Contact.find_by(id: entity_id)&.company
    when 'account' then Account.find_by(id: entity_id)&.company
    when 'deal' then Deal.find_by(id: entity_id)&.company
    when 'quote' then Quote.find_by(id: entity_id)&.company
    when 'service_ticket' then ServiceTicket.find_by(id: entity_id)&.company
    else nil
    end
  end

  private
  
  def set_created_by_name
    # Only set from user if created_by_name isn't already set
    self.created_by_name = user&.name || 'Unknown User' if created_by_name.blank?
  end
end
