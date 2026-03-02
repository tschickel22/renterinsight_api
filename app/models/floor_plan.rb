# frozen_string_literal: true

class FloorPlan < ApplicationRecord
  belongs_to :manufacturer
  belongs_to :factory, optional: true

  has_many :option_categories, dependent: :destroy
  has_many :floor_plan_options, through: :option_categories
  has_many :company_floor_plans, dependent: :destroy
  has_many :companies, through: :company_floor_plans
  has_many :configurations
  has_many :parts

  validates :name, :model_code, presence: true
  validates :model_code, uniqueness: { scope: :manufacturer_id }

  scope :active, -> { where(is_active: true) }
  scope :by_name, -> { order(:name) }

  def options_by_category
    option_categories.includes(:floor_plan_options)
                     .order(:display_order)
                     .map do |category|
      {
        id: category.id,
        name: category.name,
        description: category.description,
        is_required: category.is_required,
        allow_multiple_selections: category.allow_multiple_selections,
        options: category.floor_plan_options.order(:display_order).map do |opt|
          {
            id: opt.id,
            name: opt.name,
            description: opt.description,
            image_url: opt.image_url,
            price_impact_low: opt.price_impact_low,
            price_impact_high: opt.price_impact_high,
            is_default: opt.is_default
          }
        end
      }
    end
  end
end
