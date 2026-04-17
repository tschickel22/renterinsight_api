# frozen_string_literal: true

class MarketingContent < ApplicationRecord
  self.table_name = 'marketing_content'

  CONTENT_TYPES = %w[blog_post social_post email video_script landing_page release_note].freeze
  STATUSES      = %w[draft ready published archived].freeze

  belongs_to :knowledge_module,
             class_name: 'Knowledge::Module',
             optional: true,
             inverse_of: :marketing_contents

  belongs_to :knowledge_feature,
             class_name: 'Knowledge::Feature',
             optional: true,
             inverse_of: :marketing_contents

  validates :title,        presence: true
  validates :content_type, inclusion: { in: CONTENT_TYPES }
  validates :status,       inclusion: { in: STATUSES }

  scope :of_type,   ->(type) { where(content_type: type) }
  scope :published, -> { where(status: 'published').where.not(published_at: nil) }
  scope :draft,     -> { where(status: 'draft') }
end
