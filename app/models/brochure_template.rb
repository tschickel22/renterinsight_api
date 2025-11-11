# frozen_string_literal: true

# == Schema Information
#
# Table name: brochure_templates
#
#  id               :bigint           not null, primary key
#  name             :string           not null
#  description      :text
#  template_key     :string           not null
#  theme            :string
#  preview_image    :string
#  template_data    :jsonb
#  is_default       :boolean          default(FALSE)
#  active           :boolean          default(TRUE)
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#

class BrochureTemplate < ApplicationRecord
  # Validations
  validates :name, presence: true
  validates :template_key, presence: true, uniqueness: true
  validates :template_data, presence: true

  # Scopes
  scope :active, -> { where(active: true) }
  scope :defaults, -> { where(is_default: true) }
  scope :custom, -> { where(is_default: false) }

  # Ensure template_data has proper structure
  before_validation :set_default_template_data, if: -> { template_data.blank? }

  def set_default_template_data
    self.template_data = {
      blocks: [
        {
          id: 'hero-1',
          type: 'hero',
          config: {
            title: 'Property Collection',
            subtitle: 'Explore our featured properties'
          }
        },
        {
          id: 'gallery-1',
          type: 'gallery',
          config: {
            title: 'Featured Properties',
            maxItems: 15
          }
        }
      ]
    }
  end
end
