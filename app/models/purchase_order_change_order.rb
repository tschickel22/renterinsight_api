# frozen_string_literal: true

# A change to a factory order already sent (Truebuild::ChangeOrders).
class PurchaseOrderChangeOrder < ApplicationRecord
  STATUSES = %w[draft sent approved void].freeze
  OPEN = %w[draft sent].freeze
  # What the rep reports about the home at the factory, and what it means for
  # the change. Read to the rep and printed on the change order.
  PRODUCTION = {
    'not_released' => 'Not released to production. The factory can usually make this change.',
    'released' => 'Released to production. The factory may charge for this change or decline it.',
    'in_production' => 'In production. Many changes are no longer possible; the factory must confirm.',
    'completed' => 'Built. The home is finished; this changes a completed home.'
  }.freeze

  belongs_to :company
  belongs_to :purchase_order
  belongs_to :deal, optional: true
  belongs_to :deal_home_build, optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  validates :number, presence: true, uniqueness: { scope: :purchase_order_id }
  validates :status, inclusion: { in: STATUSES }
  validates :production_status, inclusion: { in: PRODUCTION.keys }

  scope :open, -> { where(status: OPEN) }

  def label = "#{purchase_order.po_number}-CO#{number}"
  def open? = OPEN.include?(status)
  def lines = Array(changes_list['lines'])
  def colors = Array(changes_list['colors'])
  def production_warning = PRODUCTION[production_status]
end
