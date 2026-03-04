# frozen_string_literal: true

class Factory < ApplicationRecord
  belongs_to :manufacturer
  has_many :floor_plans
  has_many :option_categories
  has_many :floor_plan_options
  has_many :parts

  validates :name, :code, presence: true
  validates :code, uniqueness: { scope: :manufacturer_id }

  scope :active, -> { where(is_active: true) }
  scope :by_name, -> { order(:name) }
end
