# frozen_string_literal: true

class BillLineItem < ApplicationRecord
  belongs_to :bill
  belongs_to :chart_of_account
  belongs_to :location, optional: true
  # The job this line is for (E68). Defaults to the bill's project; one bill
  # can split across jobs line by line.
  belongs_to :project, optional: true

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :chart_of_account_id, presence: true
  validate :project_belongs_to_company

  before_validation :default_project_from_bill

  # The line's own job, else the bill's.
  def effective_project_id
    project_id || bill&.project_id
  end

  private

  def default_project_from_bill
    self.project_id ||= bill&.project_id if new_record?
  end

  def project_belongs_to_company
    return if project_id.blank? || bill.nil?
    errors.add(:project_id, 'is not one of your projects') unless Project.where(id: project_id, company_id: bill.company_id).exists?
  end
end
