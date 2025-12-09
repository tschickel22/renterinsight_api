# frozen_string_literal: true

# == Schema Information
#
# Table name: manufacturer_claim_views
#
#  id                 :bigint           not null, primary key
#  warranty_claim_id  :bigint           not null
#  company_id         :bigint           not null
#  ip_address         :string
#  user_agent         :string
#  viewed_at          :datetime         not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#

class ManufacturerClaimView < ApplicationRecord
  belongs_to :warranty_claim
  belongs_to :company
  
  validates :viewed_at, presence: true
  
  scope :recent, -> { order(viewed_at: :desc) }
  
  # Class method to record a new view
  def self.record_view!(warranty_claim, ip_address: nil, user_agent: nil)
    create!(
      warranty_claim: warranty_claim,
      company_id: warranty_claim.company_id,
      ip_address: ip_address,
      user_agent: user_agent,
      viewed_at: Time.current
    )
  end
end
