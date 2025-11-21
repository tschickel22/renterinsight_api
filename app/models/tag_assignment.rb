# frozen_string_literal: true
class TagAssignment < ApplicationRecord
  self.table_name = 'tag_assignments'
  
  belongs_to :company, optional: true
  belongs_to :tag
  belongs_to :entity, polymorphic: true, optional: true
  
  scope :for_entity, ->(etype, eid) { where(entity_type: etype, entity_id: eid) }
  scope :for_company, ->(company_id) { where(company_id: [company_id, nil]) }
end
