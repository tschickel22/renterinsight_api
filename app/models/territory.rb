class Territory < ApplicationRecord
  belongs_to :user, optional: true
  
  has_many :territory_rules, dependent: :destroy
  has_many :deals, dependent: :nullify
  
  # Many-to-many relationship for multiple sales reps
  has_many :territory_users, dependent: :destroy
  has_many :assigned_users, through: :territory_users, source: :user
  
  validates :name, presence: true, uniqueness: true
  
  # Set default type_field if not provided
  before_validation :set_default_type_field
  
  scope :with_user, -> { where.not(user_id: nil) }
  scope :without_user, -> { where(user_id: nil) }
  scope :by_region, ->(region) { where(region: region) }
  
  def pipeline_value
    deals.open.sum(:value)
  end
  
  def deals_count
    deals.count
  end
  
  def open_deals_count
    deals.open.count
  end
  
  def won_deals_count
    deals.won.count
  end
  
  def win_rate
    closed = deals.won.count + deals.lost.count
    return 0 if closed.zero?
    (deals.won.count.to_f / closed * 100).round(2)
  end
  
  def matches_account?(account)
    territory_rules.active.all? { |rule| rule.matches?(account) }
  end
  
  private
  
  def set_default_type_field
    self.type_field ||= 'geographic'
  end
end
