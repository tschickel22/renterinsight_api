class Deal < ApplicationRecord
  include LocationAware
  include NotifiableDeal
  
  belongs_to :company, optional: true
  belongs_to :location, optional: true
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  belongs_to :user, optional: true  # FIX: Made optional to prevent 422 errors when user_id not set
  belongs_to :owner, class_name: 'User', foreign_key: 'owner_id', optional: true
  belongs_to :territory, optional: true
  belongs_to :source, optional: true
  belongs_to :vehicle, optional: true  # Added vehicle relationship
  
  has_many :deal_products, dependent: :destroy
  has_many :deal_stage_histories, dependent: :destroy
  has_many :approval_workflows, dependent: :destroy
  has_one :win_loss_report, dependent: :destroy
  has_many :activities, class_name: 'DealActivity', dependent: :destroy
  
  # Tags (polymorphic association)
  has_many :tag_assignments, as: :entity, dependent: :destroy
  has_many :tags, through: :tag_assignments
  
  # Owner helper methods
  def owner_user
    owner
  end
  
  def owner_user=(user)
    self.owner = user
  end
  
  validates :name, presence: true
  validates :value, numericality: { greater_than_or_equal_to: 0 }
  validates :probability, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :stage, presence: true, inclusion: { 
    in: %w[
      prospecting qualification needs_analysis proposal 
      negotiation closing closed_won closed_lost
      PROSPECTING QUALIFICATION NEEDS_ANALYSIS PROPOSAL 
      NEGOTIATION CLOSING CLOSED_WON CLOSED_LOST
    ], 
    message: "%{value} is not a valid stage" 
  }
  
  # Ensure at least account or contact is present
  validate :account_or_contact_required
  
  # Normalize stage to lowercase before validation
  before_validation :normalize_stage
  
  def normalize_stage
    self.stage = stage&.downcase
  end
  
  def account_or_contact_required
    if account_id.blank? && contact_id.blank?
      errors.add(:base, "Deal must have either an account or a contact")
    end
  end
  
  # Scopes
  scope :open, -> { where(stage: %w[prospecting qualification needs_analysis proposal negotiation closing]) }
  scope :won, -> { where(stage: 'closed_won') }
  scope :lost, -> { where(stage: 'closed_lost') }
  scope :by_stage, ->(stage) { where(stage: stage&.downcase) }
  scope :by_territory, ->(territory_id) { where(territory_id: territory_id) }
  scope :by_owner, ->(user_id) { where(user_id: user_id) }
  scope :by_contact, ->(contact_id) { where(contact_id: contact_id) }
  scope :by_vehicle, ->(vehicle_id) { where(vehicle_id: vehicle_id) }
  scope :expected_to_close, ->(date) { where('expected_close_date <= ?', date) }
  scope :recently_created, -> { where('created_at >= ?', 30.days.ago) }
  scope :recently_won, -> { where('won_at >= ?', 30.days.ago) }
  scope :recently_lost, -> { where('lost_at >= ?', 30.days.ago) }
  
  # Soft delete
  scope :active, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }
  
  def soft_delete
    update(deleted_at: Time.current)
  end
  
  def restore
    update(deleted_at: nil)
  end
  
  # Stage management
  def mark_as_won(reason: nil)
    update(
      stage: 'closed_won',
      won_at: Time.current,
      actual_close_date: Date.today,
      win_reason: reason
    )
  end
  
  def mark_as_lost(reason: nil, competitor: nil)
    update(
      stage: 'closed_lost',
      lost_at: Time.current,
      actual_close_date: Date.today,
      loss_reason: reason,
      competitor: competitor
    )
  end
  
  def closed?
    %w[closed_won closed_lost].include?(stage)
  end
  
  def open?
    !closed?
  end
  
  # Helper to get customer name from account or contact
  def customer_display_name
    # Prioritize manual customer_name field if set
    return customer_name if customer_name.present?
    
    # Otherwise, derive from account or contact
    if account
      account.name
    elsif contact
      "#{contact.first_name} #{contact.last_name}".strip
    else
      'Unknown'
    end
  end
  
  # Vehicle display helper
  def vehicle_display_name
    vehicle&.display_name
  end
end
