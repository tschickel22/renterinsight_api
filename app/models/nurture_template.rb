class NurtureTemplate < ApplicationRecord
  validates :company_id, :name, :channel, presence: true
end
