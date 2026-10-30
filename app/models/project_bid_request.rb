# frozen_string_literal: true

# A phase (or a whole project) sent to several contractors to bid on (E68
# step 4). ProjectBidService sends, awards, undoes and cancels.
class ProjectBidRequest < ApplicationRecord
  STATUSES = %w[open awarded cancelled].freeze

  belongs_to :company
  belongs_to :project
  belongs_to :project_phase, optional: true
  belongs_to :awarded_bid, class_name: 'ProjectBid', optional: true
  belongs_to :awarded_by, class_name: 'User', optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  has_many :bids, class_name: 'ProjectBid', dependent: :destroy

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :links_belong_to_company

  scope :open, -> { where(status: 'open') }

  def open? = status == 'open'
  def awarded? = status == 'awarded'

  # What is being bid on, for the dealer's own notices.
  def work_label
    project_phase ? "#{project_phase.name} (#{project.name})" : project.name
  end

  # What a bidder sees before the award. Project names often carry the
  # customer's name, so bidders get the work and the town instead.
  def bidder_label
    town = [project.delivery_city, project.delivery_state].compact_blank.join(', ')
    town.present? ? "#{title} in #{town}" : title
  end

  # Where it stands, for the Bids & Quotes tabs (E87).
  def stage
    return status unless open?

    bids.any? { |b| b.status == 'submitted' } ? 'ready' : 'waiting'
  end

  # Shared by the project's Bids tab and the company-wide Bids & Quotes page.
  def as_api_json(include_project: false)
    list = bids.sort_by { |b| [b.amount ? 0 : 1, b.amount.to_d, b.vendor.name.to_s] }
    lowest = list.select { |b| b.status.in?(%w[submitted awarded not_awarded]) }.map { |b| b.amount.to_d }.min
    json = {
      id: id,
      title: title,
      scope: scope,
      status: status,
      stage: stage,
      project_phase_id: project_phase_id,
      phase_name: project_phase&.name,
      bids_due_on: bids_due_on,
      start_wanted_on: start_wanted_on,
      overdue: open? && bids_due_on.present? && bids_due_on < Date.current,
      awarded_bid_id: awarded_bid_id,
      awarded_at: awarded_at,
      award_note: award_note,
      cancelled_at: cancelled_at,
      created_at: created_at,
      bids: list.map do |b|
        {
          id: b.id,
          vendor_id: b.vendor_id,
          vendor_name: b.vendor.name,
          vendor_email: b.vendor.email,
          status: b.status,
          amount: b.amount&.to_f,
          lowest: lowest.present? && b.amount.present? && b.amount.to_d == lowest && b.status != 'declined',
          can_start_on: b.can_start_on,
          duration_days: b.duration_days,
          notes: b.notes,
          submitted_at: b.submitted_at,
          entered_by_name: b.entered_by&.full_name.presence || b.entered_by&.email,
          # The contractor answered it themselves, so changing it needs a reason.
          contractor_entered: b.entered_by_id.nil? && b.submitted_at.present?,
          history: b.history,
          files: b.documents_json,
          project_cost_item_id: b.project_cost_item_id
        }
      end
    }
    return json unless include_project

    budget = project_phase ? project_phase.estimated_budget : project.budget_amount
    json.merge(
      project_id: project_id,
      project_name: project.name,
      project_number: project.try(:project_number),
      customer_name: project.customer_display_name,
      deal_id: project.deal_id,
      budget: budget&.to_f,
      responses: list.count(&:answered?),
      invited: list.size,
      low_bid: lowest&.to_f
    )
  end

  private

  def links_belong_to_company
    if project && project.company_id != company_id
      errors.add(:project_id, 'is not a project in this company')
    end
    if project_phase_id.present? && !ProjectPhase.where(id: project_phase_id, project_id: project_id).exists?
      errors.add(:project_phase_id, 'is not a phase of this project')
    end
  end
end
