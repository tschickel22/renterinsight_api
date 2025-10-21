class DealStageHistory < ApplicationRecord
  belongs_to :deal
  belongs_to :changed_by, class_name: 'User', optional: true
  
  validates :stage, presence: true
  
  before_create :calculate_duration
  
  scope :for_deal, ->(deal_id) { where(deal_id: deal_id) }
  scope :for_stage, ->(stage) { where(stage: stage) }
  scope :recent, -> { order(created_at: :desc) }
  
  private
  
  def calculate_duration
    previous_history = deal.deal_stage_histories.where(stage: previous_stage).last
    if previous_history
      self.duration = ((Time.current - previous_history.created_at) / 1.day).to_i
    end
  end
end
