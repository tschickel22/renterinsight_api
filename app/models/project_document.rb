# frozen_string_literal: true

class ProjectDocument < ApplicationRecord
  # Confidential files: stored as references, served as expiring links (PrivateFiles).
  include PrivateFileColumns
  private_file_columns :file_url

  # bid: a file a contractor sent with their bid (E87), kept on the project.
  CATEGORIES = %w[permit inspection photo video contract invoice drawing report checklist bid other].freeze
  # dealer: uploaded in the app. contractor: a contractor's work log or
  # completion photo, recorded here so it sits on the project with the rest (E102).
  SOURCES = %w[dealer contractor].freeze
  ATTACHABLE_TYPES = %w[ProjectPhase ProjectPhaseTask ProjectTask].freeze

  belongs_to :company
  belongs_to :project
  belongs_to :documentable, polymorphic: true, optional: true
  belongs_to :uploaded_by, class_name: 'User', foreign_key: 'uploaded_by_id', optional: true
  # The contractor who sent it, when source is contractor.
  belongs_to :contractor, foreign_key: :vendor_id, optional: true
  belongs_to :contractor_assignment, optional: true

  validates :title, presence: true
  validates :file_url, presence: true
  validates :file_s3_key, presence: true
  validates :file_name, presence: true
  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :source, inclusion: { in: SOURCES }
  validates :documentable_type, inclusion: { in: ATTACHABLE_TYPES }, allow_nil: true

  scope :not_deleted, -> { where(is_deleted: [false, nil]) }
  scope :by_category, ->(category) { where(category: category) if category.present? }
  scope :for_phase, ->(phase_id) { where(documentable_type: 'ProjectPhase', documentable_id: phase_id) if phase_id.present? }
  scope :for_task, ->(task_id) { where(documentable_type: 'ProjectTask', documentable_id: task_id) if task_id.present? }
  scope :photos, -> { where(category: 'photo') }
  scope :permits, -> { where(category: 'permit') }

  # The category a file gets when nobody picked one.
  def self.category_for(content_type)
    ct = content_type.to_s
    return 'photo' if ct.start_with?('image/')
    return 'video' if ct.start_with?('video/')

    'other'
  end

  def image? = content_type.to_s.start_with?('image/')
  def video? = content_type.to_s.start_with?('video/')
  def media? = image? || video?

  # The phase this file sits under, whether it was added to the phase itself
  # or to one of its sub-tasks. nil for a file on the whole project.
  def phase
    case documentable
    when ProjectPhase then documentable
    when ProjectPhaseTask then documentable.project_phase
    when ProjectTask then documentable.try(:project_phase)
    end
  end

  # The sub-task it was added to, if any.
  def phase_task
    documentable if documentable.is_a?(ProjectPhaseTask) || documentable.is_a?(ProjectTask)
  end

  # Does the buyer see it? The dealer's own tick on this file wins; otherwise
  # photos and videos follow the phase's "Share photos with the buyer"
  # setting, and the project's when the phase has none. Other files (PDFs,
  # permits, invoices) stay with the dealer until ticked one by one.
  def shown_to_client?(project_setting: project&.share_media_with_client)
    return client_visible unless client_visible.nil?
    return false unless media?

    ph = phase
    phase_setting = ph&.share_media_with_client
    phase_setting.nil? ? !!project_setting : phase_setting
  end

  # Does the contractor working the job see it? Their own uploads always;
  # otherwise the dealer's tick, and by default photos and videos only.
  def shown_to_contractor?
    return true if source == 'contractor'
    return contractor_visible unless contractor_visible.nil?

    media?
  end

  # A contractor's file belongs to their work log or completion record too, so
  # removing it from the project must not delete the stored file under them.
  def owns_stored_file?
    source != 'contractor'
  end
end
