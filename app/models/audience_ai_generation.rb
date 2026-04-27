class AudienceAiGeneration < ApplicationRecord
  STATUSES = %w[generated refined accepted discarded].freeze
  SOURCE_TYPES = %w[Lead Contact Account].freeze

  belongs_to :company
  belongs_to :user, optional: true
  belongs_to :parent_generation, class_name: 'AudienceAiGeneration', optional: true
  belongs_to :ai_query_log, optional: true
  belongs_to :audience, optional: true

  validates :prompt, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }

  before_save :stringify_jsonb_keys

  private

  def stringify_jsonb_keys
    self.context_snapshot = context_snapshot.deep_stringify_keys if context_snapshot.is_a?(Hash)
    self.generated_filter_tree = generated_filter_tree.deep_stringify_keys if generated_filter_tree.is_a?(Hash)
  end
end
