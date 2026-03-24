# frozen_string_literal: true

class ProjectCostItem < ApplicationRecord
  COST_TYPES = %w[labor materials subcontractor permit inspection equipment freight other].freeze
  CATEGORIES = %w[foundation electrical plumbing hvac skirting roofing transport setup trim drywall utility_hookup other].freeze
  STATUSES = %w[pending approved paid disputed].freeze

  belongs_to :company
  belongs_to :project
  belongs_to :project_phase, optional: true
  belongs_to :project_task, optional: true
  belongs_to :approved_by, class_name: 'User', foreign_key: 'approved_by_id', optional: true
  belongs_to :part, optional: true
  belongs_to :inventory_transaction, optional: true
  belongs_to :contractor, optional: true

  validates :description, presence: true
  validates :amount, presence: true, numericality: true
  validates :cost_type, presence: true, inclusion: { in: COST_TYPES }
  validates :category, inclusion: { in: CATEGORIES }, allow_nil: true, allow_blank: true
  validates :status, inclusion: { in: STATUSES }

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
    if contractor_id.present? && vendor_name.blank?
      self.vendor_name = contractor&.name
    end
  end

  def recalculate_parent_costs
    project_phase&.recalculate_costs! if project_phase_id.present?
    project.recalculate_costs!
  end
end
