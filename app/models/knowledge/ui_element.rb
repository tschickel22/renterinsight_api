# frozen_string_literal: true

class Knowledge::UiElement < ApplicationRecord
  self.table_name = 'knowledge_ui_elements'

  ELEMENT_TYPES = %w[button link input menu section card tab modal].freeze

  belongs_to :knowledge_feature,
             class_name: 'Knowledge::Feature',
             inverse_of: :ui_elements

  validates :selector,     presence: true
  validates :element_type, inclusion: { in: ELEMENT_TYPES }

  scope :by_type, ->(type) { where(element_type: type) }
end
