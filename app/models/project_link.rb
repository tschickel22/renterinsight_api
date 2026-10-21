# frozen_string_literal: true

# A project, one phase of it, or several phases for one fee, handed from a
# dealer to a linked installer company (E68 step 5). The dealer's project stays the record the customer
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
  # Price requests and change orders (step 6). Not named "changes": that is
  # ActiveRecord's dirty tracking.
  has_many :link_changes, class_name: 'ProjectLinkChange', dependent: :destroy
  belongs_to :link_rate_card, optional: true

  PRICE_SOURCES = %w[card dealer quote].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :fee_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :price_source, inclusion: { in: PRICE_SOURCES }, allow_nil: true
  validate :records_match_the_link

  scope :live, -> { where(status: %w[offered accepted]) }

  def offered? = status == 'offered'
  def accepted? = status == 'accepted'

  # One phase is dealer_phase; several are dealer_phase_ids; neither is the
  # whole project.
  def whole_project?
    dealer_phase_id.nil? && dealer_phase_ids.blank?
  end

  # The dealer phases this hand-off covers.
  def dealer_phases
    return [dealer_phase] if dealer_phase
    return dealer_project.project_phases.where(id: dealer_phase_ids).order(:position).to_a if dealer_phase_ids.present?

    dealer_project.project_phases.order(:position).to_a
  end

  # Sent before step 6 with no price rules: billed for whatever the
  # installer enters, and nothing holds its phases.
  def legacy_price?
    price_source.nil?
  end

  # The price is agreed: from the card or the dealer at hand-off, or a price
  # request the dealer approved.
  def price_agreed?
    !legacy_price? && !fee_amount.nil?
  end

  # What the dealer has agreed to pay: the price plus approved change orders.
  def approved_total
    fee_amount.to_d + link_changes.approved.where(kind: 'change').sum(:amount)
  end

  # A request waiting for the dealer that holds this dealer phase: one aimed
  # at it, or one for the whole job.
  def hold_for(dealer_phase_id)
    link_changes.pending.where(dealer_phase_id: [nil, dealer_phase_id]).order(:number).first
  end

  def scope_label
    return 'The whole job' if whole_project?

    names = dealer_phases.map(&:name)
    names.size > 3 ? "#{names.first(2).join(', ')} and #{names.size - 2} more" : names.to_sentence
  end

  private

  def records_match_the_link
    return unless company_link

    errors.add(:dealer_company, 'must be the link\'s dealer') unless dealer_company_id == company_link.dealer_company_id
    errors.add(:installer_company, 'must be the link\'s installer') unless installer_company_id == company_link.installer_company_id
    errors.add(:dealer_project, 'must belong to the dealer') if dealer_project && dealer_project.company_id != dealer_company_id
    errors.add(:dealer_phase, 'must be on the project') if dealer_phase && dealer_phase.project_id != dealer_project_id
    if dealer_phase_ids.present? && dealer_project &&
       dealer_project.project_phases.where(id: dealer_phase_ids).count != dealer_phase_ids.uniq.size
      errors.add(:dealer_phase_ids, 'must all be on the project')
    end
    errors.add(:installer_project, 'must belong to the installer') if installer_project && installer_project.company_id != installer_company_id
  end
end
