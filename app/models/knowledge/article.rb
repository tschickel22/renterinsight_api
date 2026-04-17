# frozen_string_literal: true

class Knowledge::Article < ApplicationRecord
  self.table_name = 'knowledge_articles'

  ARTICLE_TYPES = %w[how_to guide reference faq troubleshooting concept release_note].freeze

  # neighbor gives us nearest_neighbors(:embedding, distance: :cosine)
  # Only enable if the gem is loaded so the model doesn't blow up in environments
  # where pgvector isn't set up yet.
  has_neighbors :embedding, dimensions: 1536 if respond_to?(:has_neighbors)

  belongs_to :knowledge_module,  class_name: 'Knowledge::Module',  optional: true, inverse_of: :articles
  belongs_to :knowledge_feature, class_name: 'Knowledge::Feature', optional: true, inverse_of: :articles

  validates :title,        presence: true
  validates :slug,         presence: true, uniqueness: true
  validates :article_type, inclusion: { in: ARTICLE_TYPES }

  scope :published,   -> { where(is_published: true) }
  scope :ordered,     -> { order(:position, :title) }
  scope :of_type,     ->(type) { where(article_type: type) }
end
