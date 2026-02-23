class AgreementTemplate < ApplicationRecord
  belongs_to :company
  belongs_to :agreement_category, optional: true
  belongs_to :location, optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  has_many :agreements, dependent: :nullify

  # Validations
  validates :name, presence: true
  validates :status, presence: true, inclusion: { in: %w[draft active archived] }
  validates :template_type, presence: true, inclusion: { in: %w[upload editor] }

  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :published, -> { where(status: 'active') }
  scope :by_status, ->(status) { where(status: status) if status.present? }
  scope :by_category, ->(category) { where(category: category) if category.present? }
  scope :for_current_location, -> {
    Current.location_filtered? ? where(location_id: [Current.location_id, nil]) : all
  }

  # Status constants
  STATUS_DRAFT = 'draft'
  STATUS_ACTIVE = 'active'
  STATUS_ARCHIVED = 'archived'

  # Template type constants
  TYPE_UPLOAD = 'upload'   # PDF/DOCX uploaded, fields placed on top
  TYPE_EDITOR = 'editor'   # Built with rich text editor

  def publish!
    update!(status: STATUS_ACTIVE)
  end

  def archive!
    update!(status: STATUS_ARCHIVED)
  end

  def duplicate!(user = nil)
    new_template = dup
    new_template.name = "#{name} (Copy)"
    new_template.status = STATUS_DRAFT
    new_template.is_system_template = false
    new_template.version = 1
    new_template.created_by = user
    new_template.save!
    new_template
  end
end
