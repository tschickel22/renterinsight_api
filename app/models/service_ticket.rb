# frozen_string_literal: true

# == Schema Information
#
# Table name: service_tickets
#
#  id             :bigint           not null, primary key
#  company_id     :bigint           not null
#  account_id     :bigint
#  contact_id     :bigint
#  vehicle_id     :bigint
#  title          :string           not null
#  description    :text             not null
#  status         :string           not null, default("open")
#  priority       :string           not null, default("medium")
#  assigned_to    :string
#  scheduled_date :date
#  notes          :text
#  parts          :jsonb            default([])
#  labor          :jsonb            default([])
#  custom_fields  :jsonb            default({})
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#

class ServiceTicket < ApplicationRecord
  # Associations
  belongs_to :company
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  belongs_to :vehicle, optional: true
  
  # Validations
  validates :title, presence: true
  validates :description, presence: true
  validates :status, presence: true, inclusion: { 
    in: %w[open in_progress waiting_parts completed cancelled] 
  }
  validates :priority, presence: true, inclusion: { 
    in: %w[low medium high urgent] 
  }
  
  # Scopes
  scope :open, -> { where(status: 'open') }
  scope :in_progress, -> { where(status: 'in_progress') }
  scope :completed, -> { where(status: 'completed') }
  scope :by_priority, ->(priority) { where(priority: priority) }
  scope :assigned_to, ->(assignee) { where(assigned_to: assignee) }
  scope :scheduled_between, ->(start_date, end_date) { where(scheduled_date: start_date..end_date) }
  scope :recent, -> { order(created_at: :desc) }
  
  # Callbacks
  before_validation :set_defaults
  
  # Instance methods
  def parts_total
    parts.sum { |p| p['total'].to_f }
  end
  
  def labor_total
    labor.sum { |l| l['total'].to_f }
  end
  
  def total_cost
    parts_total + labor_total
  end
  
  def overdue?
    scheduled_date && scheduled_date < Date.today && status != 'completed'
  end
  
  private
  
  def set_defaults
    self.status ||= 'open'
    self.priority ||= 'medium'
    self.parts ||= []
    self.labor ||= []
    self.custom_fields ||= {}
  end
end
