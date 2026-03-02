# frozen_string_literal: true

class OptionCategory < ApplicationRecord
  belongs_to :floor_plan
  has_many :floor_plan_options, dependent: :destroy

  validates :name, presence: true

  scope :ordered, -> { order(:display_order) }
  scope :required, -> { where(is_required: true) }
end
