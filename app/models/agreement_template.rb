class AgreementTemplate < ApplicationRecord
  belongs_to :company
  belongs_to :agreement_category, optional: true
  belongs_to :location, optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  has_many :agreements, dependent: :nullify

  # Status constants
  STATUS_DRAFT = 'draft'
  STATUS_ACTIVE = 'active'
  STATUS_ARCHIVED = 'archived'

  # Template type constants
  TYPE_UPLOAD = 'upload'   # PDF/DOCX uploaded, fields placed on top
  TYPE_EDITOR = 'editor'   # Built with rich text editor

  # Form type constants
  FORM_TYPE_PURCHASE_AGREEMENT = 'purchase_agreement'
  FORM_TYPE_ADDENDUM = 'addendum'
  FORM_TYPE_DISCLOSURE = 'disclosure'
  FORM_TYPE_WARRANTY = 'warranty'
  FORM_TYPE_OTHER = 'other'

  FORM_TYPES = [
    FORM_TYPE_PURCHASE_AGREEMENT,
    FORM_TYPE_ADDENDUM,
    FORM_TYPE_DISCLOSURE,
    FORM_TYPE_WARRANTY,
    FORM_TYPE_OTHER
  ].freeze

  # Validations
  validates :name, presence: true
  validates :status, presence: true, inclusion: { in: %w[draft active archived] }
  validates :template_type, presence: true, inclusion: { in: %w[upload editor] }
  validates :form_type, inclusion: { in: FORM_TYPES }, allow_blank: true
  validates :state_code, length: { is: 2 }, allow_blank: true

  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :published, -> { where(status: 'active') }
  scope :by_status, ->(status) { where(status: status) if status.present? }
  scope :by_category, ->(category) { where(category: category) if category.present? }
  scope :for_current_location, -> {
    Current.location_filtered? ? where(location_id: [Current.location_id, nil]) : all
  }
  scope :platform_templates, -> { where(is_platform_template: true, is_deleted: false) }
  scope :for_state, ->(state_code) { where(state_code: state_code) if state_code.present? }
  scope :purchase_agreements, -> { where(form_type: FORM_TYPE_PURCHASE_AGREEMENT) }

  def publish!
    update!(status: STATUS_ACTIVE)
  end

  def archive!
    update!(status: STATUS_ARCHIVED)
  end

  # Class method: Get templates available to a company (company + matching platform templates)
  # When state_code is explicitly passed, filter platform templates to that state.
  # Otherwise, show ALL platform templates — user picks the right state form.
  def self.available_for_company(company, state_code: nil)
    company_templates = where(company_id: company.id, is_deleted: false)
                          .where(is_platform_template: [false, nil])

    platform_templates = where(is_platform_template: true, is_deleted: false, status: 'active')
    platform_templates = platform_templates.where(state_code: state_code) if state_code.present?

    where(id: company_templates.select(:id))
      .or(where(id: platform_templates.select(:id)))
  end

  def platform_purchase_agreement?
    is_platform_template? && form_type == FORM_TYPE_PURCHASE_AGREEMENT
  end

  def grouped_field_definitions
    return {} if custom_field_definitions.blank?

    custom_field_definitions.group_by { |f| f['fieldGroup'] || f['group'] || 'general' }
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
