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
