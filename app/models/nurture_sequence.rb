class NurtureSequence < ApplicationRecord
  has_many :nurture_steps, dependent: :destroy
  validates :name, presence: true
end
