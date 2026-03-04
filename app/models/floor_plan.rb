# frozen_string_literal: true

class FloorPlan < ApplicationRecord
  belongs_to :manufacturer
  belongs_to :factory, optional: true

  has_many :option_categories, dependent: :destroy
  has_many :floor_plan_options, through: :option_categories
  has_many :floor_plan_option_applicabilities, dependent: :destroy
  has_many :company_floor_plans, dependent: :destroy
  has_many :companies, through: :company_floor_plans
  has_many :configurations
  has_many :parts

  validates :name, :model_code, presence: true
  validates :model_code, uniqueness: { scope: :manufacturer_id }

  scope :active, -> { where(is_active: true) }
  scope :by_name, -> { order(:name) }
  scope :by_brand, ->(brand) { where(brand: brand) }
  scope :by_factory, ->(factory_id) { where(factory_id: factory_id) }
  scope :by_home_type, ->(type) { where(home_type: type) }
  scope :with_images, -> { where.not(s3_folder_path: [nil, '']) }

  def primary_image_url
    entry = images_array&.first
    entry.is_a?(Hash) ? entry['url'] : entry
  end

  def floor_plan_image_url
    entry = images_array&.at(1) || images_array&.first
    entry.is_a?(Hash) ? entry['url'] : entry
  end

  def width_ft
    width_feet
  end

  def length_ft
    length_feet
  end

  def sections
    if specifications.is_a?(Hash) && specifications.key?('sections')
      specifications['sections']
    else
      s = series.to_s.downcase
      if s.include?('single')
        'Single-Section'
      elsif s.include?('sectional') || s.include?('modular') || s.include?('genesis')
        'Multi-Section'
      elsif width_feet.present? && width_feet > 15
        'Multi-Section'
      elsif width_feet.present?
        'Single-Section'
      end
    end
  end

  def description
    specifications.is_a?(Hash) ? specifications['description'] : nil
  end

  def s3_base_url
    return nil unless s3_folder_path.present?

    "https://renterinsight-website-assets-staging.s3.us-west-2.amazonaws.com/#{s3_folder_path}"
  end

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
            swatch_image_url: opt.swatch_image_url,
            option_code: opt.option_code,
            price_dealer: opt.price_dealer,
            price_retail: opt.price_retail,
            price_impact_low: opt.price_impact_low,
            price_impact_high: opt.price_impact_high,
            material_type: opt.material_type,
            dimensions: opt.dimensions,
            is_default: opt.is_default,
            is_standard_included: opt.is_standard_included
          }
        end
      }
    end
  end

  def all_options_by_category
    # Get model-specific categories
    model_cats = option_categories.includes(:floor_plan_options).order(:display_order)

    # Get factory-scoped categories (apply to all models at this factory)
    factory_cats = if factory_id.present?
      OptionCategory.where(scope: 'factory', factory_id: factory_id)
                    .includes(:floor_plan_options)
                    .order(:display_order)
    else
      OptionCategory.none
    end

    # Get series-scoped categories
    series_cats = if series.present? && factory_id.present?
      OptionCategory.where(scope: 'series', factory_id: factory_id, series: series)
                    .includes(:floor_plan_options)
                    .order(:display_order)
    else
      OptionCategory.none
    end

    # Merge all, factory first, then series, then model-specific
    all_cats = (factory_cats.to_a + series_cats.to_a + model_cats.to_a)

    all_cats.filter_map do |category|
      options = category.floor_plan_options.order(:display_order)

      # Filter by series restriction if applicable
      if series.present?
        options = options.select { |o| o.series_restriction.nil? || o.series_restriction == series }
      end

      # Skip categories with no applicable options
      next if options.empty?

      # Check for model-specific applicability overrides
      options_data = options.map do |opt|
        applicability = FloorPlanOptionApplicability.find_by(floor_plan_id: id, floor_plan_option_id: opt.id)

        {
          id: opt.id,
          name: opt.name,
          description: opt.description,
          image_url: opt.image_url,
          swatch_image_url: opt.swatch_image_url,
          option_code: opt.option_code,
          price_dealer: applicability&.price_dealer_override || opt.price_dealer,
          price_retail: applicability&.price_retail_override || opt.price_retail,
          price_impact_low: opt.price_impact_low,
          price_impact_high: opt.price_impact_high,
          material_type: opt.material_type,
          dimensions: opt.dimensions,
          is_default: applicability&.is_default_for_model || opt.is_default,
          is_standard_included: opt.is_standard_included
        }
      end

      {
        id: category.id,
        name: category.name,
        category_key: category.category_key,
        description: category.description,
        scope: category.scope,
        is_required: category.is_required,
        allow_multiple_selections: category.allow_multiple_selections,
        options: options_data
      }
    end
  end
end
