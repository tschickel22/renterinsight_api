class WorkflowAiGeneration < ApplicationRecord
  STATUSES = %w[generated accepted refined discarded].freeze

  belongs_to :company
  belongs_to :user
  belongs_to :workflow_rule, optional: true
  belongs_to :parent_generation, class_name: 'WorkflowAiGeneration', optional: true
  belongs_to :ai_query_log, optional: true

  validates :prompt, :status, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
end
