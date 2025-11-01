# frozen_string_literal: true

class ServiceTicket < ApplicationRecord
  # Associations
  belongs_to :company
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  belongs_to :customer, optional: true, polymorphic: true
  belongs_to :vehicle, optional: true
  
  # JSON serialization for SQLite compatibility
  serialize :parts, coder: JSON
  serialize :labor, coder: JSON
  serialize :custom_fields, coder: JSON
  
  # Validations
  validates :title, presence: true
  validates :priority, presence: true, inclusion: { in: %w[low medium high urgent] }
  validates :status, presence: true, inclusion: { in: %w[open in_progress waiting_parts completed cancelled] }
  
  # Scopes
  scope :active, -> { where(deleted_at: nil) }
  scope :open, -> { where(status: 'open') }
  scope :in_progress, -> { where(status: 'in_progress') }
  scope :completed, -> { where(status: 'completed') }
  scope :by_priority, ->(priority) { where(priority: priority) }
  scope :by_status, ->(status) { where(status: status) }
  scope :assigned_to, ->(user) { where(assigned_to: user) }
  
  # Callbacks
  before_save :set_completed_date, if: :status_changed_to_completed?
  after_initialize :set_default_json_fields
  
  # Instance methods
  def soft_delete!
    update!(deleted_at: Time.current)
  end
  
  def restore!
    update!(deleted_at: nil)
  end
  
  def deleted?
    deleted_at.present?
  end
  
  def total_parts_cost
    (parts || []).sum { |part| (part['cost'].to_f || part['total'].to_f || 0) * (part['quantity'].to_i || 0) }
  end
  
  def total_labor_cost
    (labor || []).sum { |item| (item['hours'].to_f || 0) * (item['rate'].to_f || 0) }
  end
  
  def total_cost
    total_parts_cost + total_labor_cost
  end
  
  private
  
  def set_default_json_fields
    self.parts ||= []
    self.labor ||= []
    self.custom_fields ||= {}
  end
  
  def status_changed_to_completed?
    status == 'completed' && status_changed?
  end
  
  def set_completed_date
    self.completed_date = Time.current if completed_date.nil?
  end
end
