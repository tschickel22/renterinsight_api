# frozen_string_literal: true

class ProjectCostItem < ApplicationRecord
  # Confidential files: stored as references, served as expiring links (PrivateFiles).
  include PrivateFileColumns
  private_file_columns :receipt_url

  COST_TYPES = %w[labor materials subcontractor permit inspection equipment freight other].freeze
  CATEGORIES = %w[foundation electrical plumbing hvac skirting roofing transport setup trim drywall utility_hookup other].freeze
  STATUSES = %w[pending approved paid disputed].freeze

  # FK column was renamed contractor_id -> vendor_id in the unify-vendors migration.
  alias_attribute :contractor_id, :vendor_id

  belongs_to :company
  belongs_to :project
  belongs_to :project_phase, optional: true
  belongs_to :project_task, optional: true
  belongs_to :approved_by, class_name: 'User', foreign_key: 'approved_by_id', optional: true
  belongs_to :part, optional: true
  belongs_to :inventory_transaction, optional: true
  belongs_to :contractor, foreign_key: :vendor_id, optional: true
  # Any vendor type (contractor, supplier, ...) — the cost picker lists them all,
  # while :contractor only resolves vendor_type='contractor'.
  belongs_to :vendor, optional: true
  # The bill this cost is paid through (E68), e.g. a contractor's portal invoice.
  belongs_to :bill, optional: true
  # The Record Expense or manual journal entry this cost came from (E68).
  belongs_to :journal_entry, optional: true

  validates :description, presence: true
  validates :amount, presence: true, numericality: true
  validates :cost_type, presence: true, inclusion: { in: COST_TYPES }
  validates :category, inclusion: { in: CATEGORIES }, allow_nil: true, allow_blank: true
  validates :status, inclusion: { in: STATUSES }
  validate :vendor_belongs_to_company
  validate :links_belong_to_project

  scope :not_deleted, -> { where(is_deleted: [false, nil]) }
  scope :by_type, ->(type) { where(cost_type: type) if type.present? }
  scope :by_status, ->(status) { where(status: status) if status.present? }
  scope :by_phase, ->(phase_id) { where(project_phase_id: phase_id) if phase_id.present? }
  scope :by_task, ->(task_id) { where(project_task_id: task_id) if task_id.present? }
  scope :by_date_range, ->(start_date, end_date) {
    scope = all
    scope = scope.where('date >= ?', start_date) if start_date.present?
    scope = scope.where('date <= ?', end_date) if end_date.present?
    scope
  }

  before_save :auto_populate_vendor_name
  after_save :recalculate_parent_costs
  after_destroy :recalculate_parent_costs

  private

  def auto_populate_vendor_name
    if vendor_id.present? && vendor_name.blank?
      self.vendor_name = vendor&.name
    end
  end

  # contractor_id arrives from the client; never let it point at another company's vendor.
  def vendor_belongs_to_company
    return if vendor_id.blank? || !will_save_change_to_vendor_id?
    return if Vendor.where(company_id: company_id, id: vendor_id).exists?

    errors.add(:contractor_id, 'is not a vendor in this company')
  end

  # Phase, task and part ids also arrive from the client. A phase or task from
  # another project would also have its costs recalculated with this item in them.
  def links_belong_to_project
    if project_phase_id.present? && will_save_change_to_project_phase_id? &&
       !ProjectPhase.where(id: project_phase_id, project_id: project_id).exists?
      errors.add(:project_phase_id, 'is not a phase of this project')
    end
    if project_task_id.present? && will_save_change_to_project_task_id? &&
       !ProjectTask.where(id: project_task_id, project_id: project_id).exists?
      errors.add(:project_task_id, 'is not a task of this project')
    end
    if part_id.present? && will_save_change_to_part_id? && !Part.where(id: part_id, company_id: company_id).exists?
      errors.add(:part_id, 'is not a part in this company')
    end
  end

  def recalculate_parent_costs
    project_phase&.recalculate_costs! if project_phase_id.present?
    project.recalculate_costs!
  end
end
