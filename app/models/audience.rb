class Audience < ApplicationRecord
  SOURCE_TYPES = %w[Lead Contact Account].freeze

  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :created_by_user, class_name: 'User', optional: true
  belongs_to :generated_from_ai_generation, class_name: 'AudienceAiGeneration', optional: true

  has_many :audience_ai_generations
  has_many :campaign_audiences, foreign_key: :saved_audience_id, dependent: :nullify

  validates :name, presence: true, length: { maximum: 200 }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :filter_tree, presence: true
  validates :name, uniqueness: { scope: :company_id, conditions: -> { where(is_archived: false) }, message: 'already exists' }

  before_save :stringify_jsonb_keys

  scope :active, -> { where(is_archived: false) }
  scope :archived, -> { where(is_archived: true) }
  scope :for_source_type, ->(t) { where(source_type: t) }

  def estimated_age_in_minutes
    return nil unless estimated_at
    ((Time.current - estimated_at) / 60).round
  end

  private

  def stringify_jsonb_keys
    self.filter_tree = filter_tree.deep_stringify_keys if filter_tree.is_a?(Hash)
    self.exclude_filter_tree = exclude_filter_tree.deep_stringify_keys if exclude_filter_tree.is_a?(Hash)
    self.metadata = metadata.deep_stringify_keys if metadata.is_a?(Hash)
  end
end
