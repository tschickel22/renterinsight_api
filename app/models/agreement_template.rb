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
  scope :in_group, ->(group_id) { where(template_group_id: group_id) if group_id.present? }

  def publish!
    update!(status: STATUS_ACTIVE)
  end

  def archive!
    update!(status: STATUS_ARCHIVED)
  end

  # Class method: Get templates available to a company (company + matching platform templates)
  # State filtering priority:
  #   1. Explicit state_code param → show only that state
  #   2. Current location has allowed_form_states → use those
  #   3. Company.allowed_form_states is set → use those
  #   4. Auto-detect from company/location addresses → show matching states
  #   5. No state data anywhere → show all platform templates
  def self.available_for_company(company, state_code: nil)
    company_templates = where(company_id: company.id, is_deleted: false)
                          .where(is_platform_template: [false, nil])

    # Exclude master templates — only state copies are shown to users
    platform_templates = where(is_platform_template: true, is_deleted: false, status: 'active')
                           .where(is_master: [false, nil])

    effective_states = resolve_effective_states(company, state_code: state_code)

    if effective_states.any?
      platform_templates = platform_templates.where(state_code: effective_states)
    end
    # If empty, show all platform templates (no filter)

    where(id: company_templates.select(:id))
      .or(where(id: platform_templates.select(:id)))
  end

  # Resolves which state codes should be used for filtering, checking in priority order
  def self.resolve_effective_states(company, state_code: nil)
    # 1. Explicit state_code param
    return [state_code.upcase] if state_code.present?

    # 2. Current location's allowed_form_states
    if Current.location_id.present?
      location = company.locations.find_by(id: Current.location_id)
      if location&.respond_to?(:allowed_form_states)
        loc_states = location.allowed_form_states || []
        return loc_states if loc_states.any?
      end
    end

    # 3. Company's allowed_form_states
    if company.respond_to?(:allowed_form_states)
      company_states = company.allowed_form_states || []
      return company_states if company_states.any?
    end

    # 4. Auto-detect from addresses
    detected = []
    detected << company.state.upcase if company.state.present?
    company.locations.where(is_deleted: [false, nil]).pluck(:state).compact.each do |s|
      detected << s.upcase if s.present?
    end
    detected.uniq
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
