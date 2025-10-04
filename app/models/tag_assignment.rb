# frozen_string_literal: true
class TagAssignment < ApplicationRecord
  self.table_name = 'tag_assignments'
  belongs_to :tag
  belongs_to :entity, polymorphic: true
  scope :for_entity, ->(etype, eid) { where(entity_type: etype, entity_id: eid) }
end
