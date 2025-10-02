class Lead < ApplicationRecord
  belongs_to :source, optional: true  # allow creating leads while testing

  # NEW: link leads -> activities
  has_many :activities, dependent: :destroy
end
