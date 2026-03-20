# frozen_string_literal: true

class ProjectDocument < ApplicationRecord
  CATEGORIES = %w[permit inspection photo contract invoice drawing report checklist other].freeze

  belongs_to :company
  belongs_to :project
  belongs_to :documentable, polymorphic: true, optional: true
  belongs_to :uploaded_by, class_name: 'User', foreign_key: 'uploaded_by_id', optional: true

  validates :title, presence: true
  validates :file_url, presence: true
  validates :file_s3_key, presence: true
  validates :file_name, presence: true
  validates :category, presence: true, inclusion: { in: CATEGORIES }

  scope :not_deleted, -> { where(is_deleted: [false, nil]) }
  scope :by_category, ->(category) { where(category: category) if category.present? }
  scope :for_phase, ->(phase_id) { where(documentable_type: 'ProjectPhase', documentable_id: phase_id) if phase_id.present? }
  scope :for_task, ->(task_id) { where(documentable_type: 'ProjectTask', documentable_id: task_id) if task_id.present? }
  scope :photos, -> { where(category: 'photo') }
  scope :permits, -> { where(category: 'permit') }
end
