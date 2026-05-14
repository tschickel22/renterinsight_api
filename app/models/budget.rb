# frozen_string_literal: true

class Budget < ApplicationRecord
  STATUSES = %w[draft active locked archived].freeze
  CONSOLIDATION_TYPES = %w[standalone consolidated].freeze
  BUDGET_TYPES = %w[annual quarterly].freeze

  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :creator, class_name: 'User', foreign_key: 'created_by_id', optional: true
  belongs_to :approver, class_name: 'User', foreign_key: 'approved_by_id', optional: true
  belongs_to :locker,   class_name: 'User', foreign_key: 'locked_by_id',   optional: true

  has_many :budget_lines, dependent: :destroy
  accepts_nested_attributes_for :budget_lines, allow_destroy: true

  validates :name, presence: true
  validates :fiscal_year, presence: true,
                          numericality: { only_integer: true,
                                          greater_than_or_equal_to: 2020,
                                          less_than_or_equal_to: 2100 }
  validates :status,             inclusion: { in: STATUSES }
  validates :budget_type,        inclusion: { in: BUDGET_TYPES }
  validates :consolidation_type, inclusion: { in: CONSOLIDATION_TYPES }
  validates :name, uniqueness: { scope: [:company_id, :fiscal_year, :location_id] }

  scope :by_status,       ->(s)    { where(status: s) }
  scope :by_fiscal_year,  ->(y)    { where(fiscal_year: y) }
  scope :standalone,      ->       { where(consolidation_type: 'standalone') }
  scope :consolidated,    ->       { where(consolidation_type: 'consolidated') }
  scope :corporate,       ->       { where(location_id: nil) }
  scope :for_location,    ->(loc)  { where(location_id: loc) }
  scope :for_current_location, -> {
    if Current.location_filtered?
      where('budgets.location_id = ? OR budgets.location_id IS NULL', Current.location_id)
    else
      all
    end
  }

  after_commit :trigger_consolidation_rebuild,
               if: -> { standalone? && location_id.present? && !Rails.env.test? }
  after_commit :trigger_consolidation_cleanup,
               on: :destroy,
               if: -> { standalone? && location_id.present? && !Rails.env.test? }

  def locked?       ; status == 'locked'   end
  def draft?        ; status == 'draft'    end
  def active?       ; status == 'active'   end
  def archived?     ; status == 'archived' end
  def consolidated? ; consolidation_type == 'consolidated' end
  def standalone?   ; consolidation_type == 'standalone'   end
  def corporate?    ; location_id.nil? end
  def editable?     ; !locked? && !archived? && !consolidated? end

  def location_name
    return location.name if location
    consolidated? ? 'All Locations (Consolidated)' : 'Company-Wide'
  end

  def total_amount
    budget_lines.sum(:annual_total)
  end

  private

  def trigger_consolidation_rebuild
    BudgetService.rebuild_consolidated(company, fiscal_year)
  rescue => e
    Rails.logger.error("[Budget] Failed to rebuild consolidated budget: #{e.message}")
  end

  def trigger_consolidation_cleanup
    BudgetService.rebuild_consolidated(company, fiscal_year)
  rescue => e
    Rails.logger.error("[Budget] Failed to rebuild consolidated budget after destroy: #{e.message}")
  end
end
