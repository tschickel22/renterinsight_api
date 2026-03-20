# frozen_string_literal: true

class ProjectMaterialUsage < ApplicationRecord
  STATUSES = %w[allocated checked_out partially_used fully_used returned].freeze

  belongs_to :company
  belongs_to :project
  belongs_to :part
  belongs_to :location
  belongs_to :project_phase, optional: true
  belongs_to :project_task, optional: true
  belongs_to :bin, optional: true
  belongs_to :checked_out_by, class_name: 'User', foreign_key: 'checked_out_by_id', optional: true
  belongs_to :used_by, class_name: 'User', foreign_key: 'used_by_id', optional: true
  belongs_to :returned_by, class_name: 'User', foreign_key: 'returned_by_id', optional: true

  validates :quantity_allocated, presence: true, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }

  scope :not_deleted, -> { where(is_deleted: [false, nil]) }
  scope :active, -> { where.not(status: %w[fully_used returned]) }
  scope :by_status, ->(status) { where(status: status) if status.present? }
  scope :for_phase, ->(phase_id) { where(project_phase_id: phase_id) if phase_id.present? }
  scope :for_task, ->(task_id) { where(project_task_id: task_id) if task_id.present? }

  # Look up inventory transactions that reference this material usage
  def inventory_transactions
    InventoryTransaction.where(reference_type: 'ProjectMaterialUsage', reference_id: id)
  end

  # Check out parts from inventory (deducts from stock)
  def check_out!(user, quantity = nil)
    quantity = (quantity || quantity_allocated).to_f
    raise 'Cannot check out more than allocated' if quantity > (quantity_allocated - quantity_checked_out)
    raise 'Insufficient stock available' unless stock_available?(quantity)

    transaction do
      svc = InventoryTransactionService.new(company, user)
      txn = svc.consume(
        part_id: part_id,
        location_id: location_id,
        bin_id: bin_id,
        quantity: quantity,
        reference_type: 'ProjectMaterialUsage',
        reference_id: id,
        notes: "Checked out for Project ##{project.project_number}"
      )
      raise svc.errors.join(', ') unless txn

      self.quantity_checked_out += quantity
      self.checked_out_at = Time.current
      self.checked_out_by = user
      update_status!
      save!
    end
  end

  # Mark checked-out parts as used (confirmed consumed)
  def mark_used!(user, qty_used)
    qty_used = qty_used.to_f
    available_to_use = quantity_checked_out - quantity_used - quantity_returned
    raise 'Cannot mark more as used than checked out' if qty_used > available_to_use

    transaction do
      self.quantity_used += qty_used
      self.used_at = Time.current
      self.used_by = user
      update_status!
      save!

      # Auto-create cost item for materials consumed
      project.project_cost_items.create!(
        company_id: company_id,
        project_phase_id: project_phase_id,
        project_task_id: project_task_id,
        cost_type: 'materials',
        description: "#{part.name} - #{qty_used} used",
        amount: qty_used * (unit_cost || 0),
        quantity: qty_used,
        unit_price: unit_cost,
        part_id: part_id,
        date: Date.current,
        status: 'approved'
      )
    end
  end

  # Return unused parts back to inventory
  def return_unused!(user, quantity_to_return)
    quantity_to_return = quantity_to_return.to_f
    available_to_return = quantity_checked_out - quantity_used - quantity_returned
    raise 'Cannot return more than available' if quantity_to_return > available_to_return

    transaction do
      svc = InventoryTransactionService.new(company, user)
      txn = svc.return_inventory(
        part_id: part_id,
        location_id: location_id,
        bin_id: bin_id,
        quantity: quantity_to_return,
        unit_cost: unit_cost,
        reference_type: 'ProjectMaterialUsage',
        reference_id: id,
        notes: "Returned from Project ##{project.project_number}"
      )
      raise svc.errors.join(', ') unless txn

      self.quantity_returned += quantity_to_return
      self.returned_at = Time.current
      self.returned_by = user
      update_status!
      save!
    end
  end

  def stock_available?(quantity = nil)
    quantity ||= quantity_allocated
    return false unless part && location_id

    stock = part.stock_balances.find_by(location_id: location_id, bin_id: bin_id)
    return false unless stock

    stock.available >= quantity
  end

  def total_cost
    (quantity_used || 0) * (unit_cost || 0)
  end

  # Full reversal: return outstanding inventory, remove cost items, soft-delete
  def reverse!(user)
    transaction do
      # 1. Return any checked-out-but-not-returned parts to inventory
      outstanding = quantity_checked_out - quantity_returned
      if outstanding > 0
        svc = InventoryTransactionService.new(company, user)
        txn = svc.return_inventory(
          part_id: part_id,
          location_id: location_id,
          bin_id: bin_id,
          quantity: outstanding,
          unit_cost: unit_cost,
          reference_type: 'ProjectMaterialUsage',
          reference_id: id,
          notes: "Reversed/undone for Project ##{project.project_number}"
        )
        raise svc.errors.join(', ') unless txn
      end

      # 2. Soft-delete any auto-created cost items linked to this material usage
      project.project_cost_items
        .where(part_id: part_id, cost_type: 'materials', is_deleted: [false, nil])
        .where('description LIKE ?', "%#{part.name}%")
        .update_all(is_deleted: true, updated_at: Time.current)

      # 3. Recalculate project costs after removing cost items
      project.recalculate_costs!
      project_phase&.recalculate_costs! if project_phase_id.present?

      # 4. Soft-delete this usage record
      update!(is_deleted: true)
    end
  end

  def update_status!
    self.status = if quantity_returned > 0 && (quantity_used + quantity_returned) >= quantity_checked_out
                    'returned'
                  elsif quantity_used > 0 && quantity_used >= quantity_checked_out
                    'fully_used'
                  elsif quantity_used > 0
                    'partially_used'
                  elsif quantity_checked_out > 0
                    'checked_out'
                  else
                    'allocated'
                  end
  end
end
