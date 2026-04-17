# frozen_string_literal: true

class Tour < ApplicationRecord
  TRIGGER_TYPES = %w[manual auto_on_first_visit on_action scheduled].freeze

  belongs_to :knowledge_module,
             class_name: 'Knowledge::Module',
             optional: true,
             inverse_of: :tours

  has_many :steps,
           -> { order(:position) },
           class_name: 'TourStep',
           dependent: :destroy,
           inverse_of: :tour

  has_many :completions,
           class_name: 'UserTourCompletion',
           dependent: :destroy,
           inverse_of: :tour

  validates :key,          presence: true, uniqueness: { scope: :knowledge_module_id }
  validates :name,         presence: true
  validates :trigger_type, inclusion: { in: TRIGGER_TYPES }

  scope :active,  -> { where(is_active: true) }
  scope :ordered, -> { order(:position, :name) }
end
