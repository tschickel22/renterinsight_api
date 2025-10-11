class Note < ApplicationRecord
  belongs_to :user, optional: true
  
  validates :content, presence: true
  validates :entity_type, presence: true
  validates :entity_id, presence: true
  
  scope :for_entity, ->(type, id) { where(entity_type: type, entity_id: id) }
  scope :recent, -> { order(created_at: :desc) }
  
  before_save :set_created_by_name
  
  private
  
  def set_created_by_name
    self.created_by_name ||= user&.name || 'Unknown User'
  end
end
