# frozen_string_literal: true

# One thing a client owes us, or we owe them, while they start on DealerTide
# (backlog E97). Shown to every user of the client company in Getting
# started; managed by platform admins. Files go to the private bucket.
class OnboardingItem < ApplicationRecord
  OWED_BY = %w[client dealertide].freeze
  STATUSES = %w[open done not_needed].freeze

  belongs_to :company
  belongs_to :template_item, class_name: 'OnboardingTemplateItem', optional: true, inverse_of: :onboarding_items
  belongs_to :assignee, class_name: 'User', optional: true
  belongs_to :done_by, class_name: 'User', optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  has_many :events, class_name: 'OnboardingEvent', dependent: :nullify
  has_many_attached :files

  validates :section, :title, presence: true
  validates :owed_by, inclusion: { in: OWED_BY }
  validates :status, inclusion: { in: STATUSES }
  validate :assignee_belongs_to_a_side

  scope :ordered, -> { order(:section, :position, :id) }
  scope :open, -> { where(status: 'open') }

  def open? = status == 'open'
  def client_owes? = owed_by == 'client'
  def overdue? = open? && due_on.present? && due_on < Date.current

  private

  # Someone at the client, or one of us.
  def assignee_belongs_to_a_side
    return unless assignee
    return if assignee.company_id == company_id || assignee.platform_admin?

    errors.add(:assignee, 'must work at this client or at DealerTide')
  end
end
