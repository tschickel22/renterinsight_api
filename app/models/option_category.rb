# frozen_string_literal: true

class OptionCategory < ApplicationRecord
  belongs_to :floor_plan, optional: true
  belongs_to :factory, optional: true
  has_many :floor_plan_options, dependent: :destroy

  validates :name, presence: true

  scope :ordered, -> { order(:display_order) }
  scope :required, -> { where(is_required: true) }
  scope :global, -> { where(scope: 'global') }
  scope :for_factory, ->(factory_id) { where(scope: 'factory', factory_id: factory_id) }
  scope :for_series, ->(series_name) { where(scope: 'series', series: series_name) }
  scope :for_model, ->(floor_plan_id) { where(floor_plan_id: floor_plan_id) }
  scope :by_scope, ->(scope_value) { where(scope: scope_value) }
end
