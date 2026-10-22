# frozen_string_literal: true

# One contractor's answer to a bid request: invited until they bid or
# decline, then awarded or not when the dealer picks one (E68 step 4).
class ProjectBid < ApplicationRecord
  STATUSES = %w[invited submitted declined awarded not_awarded].freeze

  belongs_to :company
  belongs_to :project_bid_request
  belongs_to :vendor
  belongs_to :entered_by, class_name: 'User', optional: true
  belongs_to :project_cost_item, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :vendor_id, uniqueness: { scope: :project_bid_request_id, message: 'is already invited to this request' }
  validates :amount, numericality: { greater_than: 0 }, if: -> { status.in?(%w[submitted awarded]) }
  validates :duration_days, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :vendor_belongs_to_company

  def answered? = status.in?(%w[submitted declined awarded not_awarded])

  private

  def vendor_belongs_to_company
    return if vendor_id.blank? || !will_save_change_to_vendor_id?
    return if Vendor.where(company_id: company_id, id: vendor_id).exists?

    errors.add(:vendor_id, 'is not a vendor in this company')
  end
end
