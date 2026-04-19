# frozen_string_literal: true

# Top-level entry in the unified knowledge base. Mirrors the 58 modules produced
# by the BE scan (knowledge-scan-backend.json). Intentionally named
# Knowledge::Module inside this namespace — the name only shadows Ruby's ::Module
# class for direct unqualified references *inside* the Knowledge namespace, which
# we don't rely on.
class Knowledge::Module < ApplicationRecord
  self.table_name = 'knowledge_modules'

  has_many :features,
           class_name: 'Knowledge::Feature',
           foreign_key: :knowledge_module_id,
           dependent: :destroy,
           inverse_of: :knowledge_module

  has_many :articles,
           class_name: 'Knowledge::Article',
           foreign_key: :knowledge_module_id,
           dependent: :nullify,
           inverse_of: :knowledge_module

  has_many :tours,
           class_name: '::Tour',
           foreign_key: :knowledge_module_id,
           dependent: :destroy,
           inverse_of: :knowledge_module

  has_many :marketing_contents,
           class_name: '::MarketingContent',
           foreign_key: :knowledge_module_id,
           dependent: :nullify,
           inverse_of: :knowledge_module

  validates :key,  presence: true, uniqueness: true
  validates :name, presence: true

  scope :active,   -> { where(is_active: true) }
  scope :ordered,  -> { order(:position, :name) }
end
