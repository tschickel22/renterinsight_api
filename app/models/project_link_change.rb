# frozen_string_literal: true

# A request on a handed-off job that the dealer approves before the work
# starts (E68 step 6): the job's price (a quote, or a price other than the one
# offered) or a change order. While it waits, the phases it covers that
# haven't started can't start.
class ProjectLinkChange < ApplicationRecord
  KINDS = %w[price change].freeze
  STATUSES = %w[pending approved declined withdrawn].freeze

  belongs_to :project_link
  belongs_to :dealer_phase, class_name: 'ProjectPhase', optional: true
  belongs_to :requested_by, class_name: 'User', optional: true
  belongs_to :decided_by, class_name: 'User', optional: true
  belongs_to :dealer_cost_item, class_name: 'ProjectCostItem', optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :amount, numericality: { greater_than: 0 }
  validate :phase_is_on_the_job

  scope :pending, -> { where(status: 'pending') }
  scope :approved, -> { where(status: 'approved') }

  def pending? = status == 'pending'
  def price? = kind == 'price'

  def label
    price? ? 'Price' : "Change order #{number}"
  end

  private

  def phase_is_on_the_job
    return unless dealer_phase_id && project_link

    errors.add(:dealer_phase, 'must be on this job') unless project_link.dealer_phases.map(&:id).include?(dealer_phase_id)
  end
end
