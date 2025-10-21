class Deal < ApplicationRecord
  belongs_to :account
  belongs_to :user
  belongs_to :territory, optional: true
  
  has_many :deal_products, dependent: :destroy
  has_many :deal_stage_histories, dependent: :destroy
  has_many :approval_workflows, dependent: :destroy
  has_one :win_loss_report, dependent: :destroy
  
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
  
  # Normalize stage to lowercase before validation
  before_validation :normalize_stage
  
  def normalize_stage
    self.stage = stage&.downcase
  end
  
  # Scopes
  scope :open, -> { where(stage: %w[prospecting qualification needs_analysis proposal negotiation closing]) }
  scope :won, -> { where(stage: 'closed_won') }
  scope :lost, -> { where(stage: 'closed_lost') }
  scope :by_stage, ->(stage) { where(stage: stage&.downcase) }
  scope :by_territory, ->(territory_id) { where(territory_id: territory_id) }
  scope :by_owner, ->(user_id) { where(user_id: user_id) }
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
end
