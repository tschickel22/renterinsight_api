# frozen_string_literal: true

# The standard onboarding list every new client starts from (backlog E97).
# Editing it changes what the next client gets; clients already started keep
# their own copy of each item.
class OnboardingTemplateItem < ApplicationRecord
  has_many :onboarding_items, foreign_key: :template_item_id, dependent: :nullify, inverse_of: :template_item

  validates :section, :title, presence: true
  validates :owed_by, inclusion: { in: OnboardingItem::OWED_BY }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:section, :position, :id) }
end
