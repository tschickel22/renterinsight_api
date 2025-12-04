# frozen_string_literal: true

# == Schema Information
#
# Table name: service_tickets
#
#  id                      :bigint           not null, primary key
#  company_id              :bigint           not null
#  account_id              :bigint
#  contact_id              :bigint
#  vehicle_id              :bigint
#  title                   :string           not null
#  description             :text             not null
#  status                  :string           not null, default("open")
#  priority                :string           not null, default("medium")
#  assigned_to             :string
#  scheduled_date          :date
#  notes                   :text
#  parts                   :jsonb            default([])
#  labor                   :jsonb            default([])
#  custom_fields           :jsonb            default({})
#  is_warranty_suspected   :boolean          default(FALSE), not null
#  is_warranty_confirmed   :boolean          default(FALSE), not null
#  warranty_claim_id       :bigint
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#

class ServiceTicket < ApplicationRecord
  include LocationAware
  
  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  belongs_to :vehicle, optional: true
  belongs_to :warranty_claim, optional: true
  has_one :warranty_claim_owned, class_name: 'WarrantyClaim', foreign_key: :service_ticket_id, dependent: :restrict_with_error
  
  # Active Storage for attachments (photos, videos, documents)
  has_many_attached :attachments
  
  # Serialize JSON columns to ensure they're always arrays
  attribute :parts, :json, default: []
  attribute :labor, :json, default: []
  attribute :custom_fields, :json, default: {}
  
  # Validations
  validates :title, presence: true
  validates :description, presence: true
  validates :status, presence: true, inclusion: { 
    in: %w[open in_progress waiting_on_manufacturer waiting_parts completed cancelled] 
  }
  validates :priority, presence: true, inclusion: { 
    in: %w[low medium high urgent] 
  }
  
  # Scopes
  scope :open, -> { where(status: 'open') }
  scope :in_progress, -> { where(status: 'in_progress') }
  scope :waiting_on_manufacturer, -> { where(status: 'waiting_on_manufacturer') }
  scope :completed, -> { where(status: 'completed') }
  scope :by_priority, ->(priority) { where(priority: priority) }
  scope :assigned_to, ->(assignee) { where(assigned_to: assignee) }
  scope :scheduled_between, ->(start_date, end_date) { where(scheduled_date: start_date..end_date) }
  scope :recent, -> { order(created_at: :desc) }
  scope :warranty_suspected, -> { where(is_warranty_suspected: true) }
  scope :warranty_confirmed, -> { where(is_warranty_confirmed: true) }
  scope :with_warranty_claims, -> { where.not(warranty_claim_id: nil) }
  
  # Callbacks
  before_validation :set_defaults
  
  # Instance methods
  def parts_total
    parts_array = parts.is_a?(Array) ? parts : (parts.present? ? (JSON.parse(parts) rescue []) : [])
    parts_array.sum { |p| p['total'].to_f }
  end
  
  def labor_total
    labor_array = labor.is_a?(Array) ? labor : (labor.present? ? (JSON.parse(labor) rescue []) : [])
    labor_array.sum { |l| l['total'].to_f }
  end
  
  def total_cost
    parts_total + labor_total
  end
  
  def overdue?
    scheduled_date && scheduled_date < Date.today && status != 'completed'
  end
  
  # Warranty Methods
  def has_warranty_claim?
    warranty_claim_owned.present?
  end
  
  def warranty_status
    return nil unless has_warranty_claim?
    warranty_claim_owned.status
  end
  
  def mark_warranty_suspected!
    update!(is_warranty_suspected: true)
  end
  
  def confirm_warranty!
    update!(is_warranty_confirmed: true)
  end
  
  def create_warranty_claim!(manufacturer_id:, estimated_amount: nil, parts: nil, labor: nil, notes: nil, submitted_by:)
    raise 'Warranty claim already exists' if has_warranty_claim?
    
    claim = WarrantyClaim.create!(
      company_id: company_id,
      location_id: location_id,
      service_ticket_id: id,
      manufacturer_id: manufacturer_id,
      estimated_amount: estimated_amount || total_cost,
      parts: parts || self.parts,
      labor: labor || self.labor,
      notes_to_manufacturer: notes,
      submitted_by: submitted_by,
      status: 'draft'
    )
    
    update!(
      warranty_claim_id: claim.id,
      is_warranty_confirmed: true,
      status: 'waiting_on_manufacturer'
    )
    
    claim
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
