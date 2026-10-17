# frozen_string_literal: true

# A project, or one phase of it, handed from a dealer to a linked installer
# company (E68 step 5). The dealer's project stays the record the customer
# follows; the installer works its own copy, made when it accepts.
class ProjectLink < ApplicationRecord
  STATUSES = %w[offered accepted declined cancelled done].freeze

  belongs_to :company_link
  belongs_to :dealer_company, class_name: 'Company'
  belongs_to :installer_company, class_name: 'Company'
  belongs_to :dealer_project, class_name: 'Project'
  belongs_to :dealer_phase, class_name: 'ProjectPhase', optional: true
  belongs_to :installer_project, class_name: 'Project', optional: true
  belongs_to :offered_by, class_name: 'User', optional: true
  belongs_to :responded_by, class_name: 'User', optional: true
  belongs_to :dealer_cost_item, class_name: 'ProjectCostItem', optional: true
  belongs_to :installer_invoice, class_name: 'Invoice', optional: true
  belongs_to :dealer_bill, class_name: 'Bill', optional: true
  has_many :link_phases, class_name: 'ProjectLinkPhase', dependent: :delete_all

  validates :status, inclusion: { in: STATUSES }
  validates :fee_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :records_match_the_link

  scope :live, -> { where(status: %w[offered accepted]) }

  def offered? = status == 'offered'
  def accepted? = status == 'accepted'

  # The dealer phases this hand-off covers.
  def dealer_phases
    dealer_phase ? [dealer_phase] : dealer_project.project_phases.order(:position).to_a
  end

  def scope_label
    dealer_phase ? dealer_phase.name : 'The whole job'
  end

  private

  def records_match_the_link
    return unless company_link

    errors.add(:dealer_company, 'must be the link\'s dealer') unless dealer_company_id == company_link.dealer_company_id
    errors.add(:installer_company, 'must be the link\'s installer') unless installer_company_id == company_link.installer_company_id
    errors.add(:dealer_project, 'must belong to the dealer') if dealer_project && dealer_project.company_id != dealer_company_id
    errors.add(:dealer_phase, 'must be on the project') if dealer_phase && dealer_phase.project_id != dealer_project_id
    errors.add(:installer_project, 'must belong to the installer') if installer_project && installer_project.company_id != installer_company_id
  end
end
