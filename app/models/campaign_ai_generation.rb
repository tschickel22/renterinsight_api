class CampaignAiGeneration < ApplicationRecord
  STATUSES = %w[generated accepted edited_then_accepted discarded refined].freeze

  belongs_to :company
  belongs_to :user
  belongs_to :campaign, optional: true
  belongs_to :template_used, class_name: 'CampaignTemplate', foreign_key: :template_id_used, optional: true
  belongs_to :parent_generation, class_name: 'CampaignAiGeneration', optional: true
  belongs_to :ai_query_log, optional: true

  validates :prompt, :status, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
end
