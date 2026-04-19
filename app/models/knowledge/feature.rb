# frozen_string_literal: true

class Knowledge::Feature < ApplicationRecord
  self.table_name = 'knowledge_features'

  belongs_to :knowledge_module,
             class_name: 'Knowledge::Module',
             inverse_of: :features

  has_many :ui_elements,
           class_name: 'Knowledge::UiElement',
           foreign_key: :knowledge_feature_id,
           dependent: :destroy,
           inverse_of: :knowledge_feature

  has_many :articles,
           class_name: 'Knowledge::Article',
           foreign_key: :knowledge_feature_id,
           dependent: :nullify,
           inverse_of: :knowledge_feature

  has_many :marketing_contents,
           class_name: '::MarketingContent',
           foreign_key: :knowledge_feature_id,
           dependent: :nullify,
           inverse_of: :knowledge_feature

  validates :key,  presence: true, uniqueness: { scope: :knowledge_module_id }
  validates :name, presence: true

  scope :ordered,         -> { order(:position, :name) }
  scope :with_permission, ->(key) { where(permission_key: key) }
end
