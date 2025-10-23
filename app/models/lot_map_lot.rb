# frozen_string_literal: true

# == Schema Information
#
# Table name: lot_map_lots
#
#  id                     :integer          not null, primary key
#  layout_id              :integer          not null
#  number                 :string           not null
#  position               :text             (stored as JSON)
#  status                 :string           default("empty")
#  assigned_inventory_id  :integer
#  assigned_inventory_info :string
#  area                   :string
#  notes                  :text
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#

class LotMapLot < ApplicationRecord
  # Serialize JSON fields for SQLite
  serialize :position, coder: JSON

  # Associations
  belongs_to :layout, class_name: 'LotMapLayout', foreign_key: :layout_id
  has_many :history_entries, class_name: 'LotMapHistoryEntry', foreign_key: :lot_id, dependent: :destroy

  # Validations
  validates :number, presence: true
  validates :status, presence: true, inclusion: { 
    in: %w[empty available sold_pending reserved service display new_arrival wholesale in_transit maintenance] 
  }

  # Scopes
  scope :for_layout, ->(layout_id) { where(layout_id: layout_id) }
  scope :by_status, ->(status) { where(status: status) }
  scope :assigned, -> { where.not(assigned_inventory_id: nil) }
  scope :unassigned, -> { where(assigned_inventory_id: nil) }
  scope :by_area, ->(area) { where(area: area) }

  # Callbacks
  after_save :update_layout_lot_count
  after_destroy :update_layout_lot_count

  # Instance Methods
  def assign_inventory!(inventory_id, inventory_info, user_id: nil, user_name: nil)
    old_status = status
    transaction do
      update!(
        assigned_inventory_id: inventory_id,
        assigned_inventory_info: inventory_info,
        status: 'available'
      )
      
      create_history_entry(
        action: 'ASSIGNED',
        inventory_id: inventory_id,
        old_status: old_status,
        new_status: 'available',
        user_id: user_id,
        user_name: user_name,
        details: "Assigned inventory: #{inventory_info}"
      )
    end
  end

  def unassign_inventory!(user_id: nil, user_name: nil)
    old_inventory_id = assigned_inventory_id
    old_inventory_info = assigned_inventory_info
    old_status = status
    
    transaction do
      update!(
        assigned_inventory_id: nil,
        assigned_inventory_info: nil,
        status: 'empty'
      )
      
      create_history_entry(
        action: 'UNASSIGNED',
        inventory_id: old_inventory_id,
        old_status: old_status,
        new_status: 'empty',
        user_id: user_id,
        user_name: user_name,
        details: "Unassigned inventory: #{old_inventory_info}"
      )
    end
  end

  def change_status!(new_status, user_id: nil, user_name: nil)
    old_status = status
    
    transaction do
      update!(status: new_status)
      
      create_history_entry(
        action: 'STATUS_CHANGE',
        inventory_id: assigned_inventory_id,
        old_status: old_status,
        new_status: new_status,
        user_id: user_id,
        user_name: user_name,
        details: "Status changed from #{old_status} to #{new_status}"
      )
    end
  end

  private

  def create_history_entry(attributes)
    history_entries.create!(attributes)
  end

  def update_layout_lot_count
    layout.update_lot_count!
  end
end
