# frozen_string_literal: true

class Knowledge::Article < ApplicationRecord
  self.table_name = 'knowledge_articles'

  # Section bookends (deal-to-cash plan item 16): the words around a training
  # area's "Watch all". section-intro-<area> plays before the first video (why the
  # area matters) and section-recap-<area> after the last (what to watch out for).
  # The list of videos, the runtime and the next area are generated; only these
  # few sentences are written. They are never offered as articles on their own.
  BOOKEND_TYPES = %w[section_intro section_recap].freeze
  BOOKEND_SLUG = /\Asection-(intro|recap)-[a-z0-9_-]+\z/
  ARTICLE_TYPES = (%w[how_to guide reference faq troubleshooting concept release_note] + BOOKEND_TYPES).freeze

  # neighbor gives us nearest_neighbors(:embedding, distance: :cosine)
  # Only enable if the gem is loaded so the model doesn't blow up in environments
  # where pgvector isn't set up yet.
  has_neighbors :embedding, dimensions: 1536 if respond_to?(:has_neighbors)

  belongs_to :knowledge_module,  class_name: 'Knowledge::Module',  optional: true, inverse_of: :articles
  belongs_to :knowledge_feature, class_name: 'Knowledge::Feature', optional: true, inverse_of: :articles

  # Written in Knowledge admin by slug alone (its form has no type picker).
  before_validation { self.article_type = "section_#{slug[BOOKEND_SLUG, 1]}" if slug.to_s.match?(BOOKEND_SLUG) }

  validates :title,        presence: true
  validates :slug,         presence: true, uniqueness: true
  validates :article_type, inclusion: { in: ARTICLE_TYPES }

  scope :published,   -> { where(is_published: true) }
  scope :ordered,     -> { order(:position, :title) }
  scope :of_type,     ->(type) { where(article_type: type) }
  # Articles that stand on their own: everything but release notes and section bookends.
  scope :standalone,  -> { where.not(article_type: ['release_note', *BOOKEND_TYPES]) }
end
