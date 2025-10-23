# frozen_string_literal: true

# == Schema Information
#
# Table name: lot_map_history_entries
#
#  id           :uuid             not null, primary key
#  lot_id       :uuid             not null
#  action       :string           not null
#  inventory_id :uuid
#  old_status   :string
#  new_status   :string
#  user_id      :uuid
#  user_name    :string
#  details      :text
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#

class LotMapHistoryEntry < ApplicationRecord
  # Associations
  belongs_to :lot, class_name: 'LotMapLot', foreign_key: :lot_id

  # Validations
  validates :action, presence: true, inclusion: { 
    in: %w[ASSIGNED UNASSIGNED STATUS_CHANGE CREATED UPDATED] 
  }

  # Scopes
  scope :for_lot, ->(lot_id) { where(lot_id: lot_id) }
  scope :by_action, ->(action) { where(action: action) }
  scope :for_inventory, ->(inventory_id) { where(inventory_id: inventory_id) }
  scope :by_user, ->(user_id) { where(user_id: user_id) }
  scope :recent, -> { order(created_at: :desc) }

  # Class Methods
  def self.for_layout(layout_id)
    joins(:lot).where(lot_map_lots: { layout_id: layout_id }).order(created_at: :desc)
  end

  # Instance Methods
  def timestamp
    created_at
  end

  # JSON Representation
  def as_json(options = {})
    super(options.merge(
      methods: [:timestamp]
    ))
  end
end
