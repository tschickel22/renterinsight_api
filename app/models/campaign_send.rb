class CampaignSend < ApplicationRecord
  belongs_to :campaign
  belongs_to :campaign_step
  belongs_to :campaign_enrollment
  belongs_to :communication, optional: true
  has_many :campaign_link_tokens, dependent: :destroy
end
