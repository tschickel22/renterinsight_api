class TerritoryUser < ApplicationRecord
  belongs_to :territory
  belongs_to :user

  validates :territory_id, uniqueness: { scope: :user_id, message: "User already assigned to this territory" }
end
