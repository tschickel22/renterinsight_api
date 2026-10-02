# frozen_string_literal: true

class Factory < ApplicationRecord
  belongs_to :manufacturer
  has_many :parts
  has_many :catalog_plans, dependent: :nullify
  has_many :catalog_price_books, dependent: :restrict_with_error

  validates :name, :code, presence: true
  validates :code, uniqueness: { scope: :manufacturer_id }

  scope :active, -> { where(is_active: true) }
  scope :by_name, -> { order(:name) }

  # The brand buyers and dealers know the homes by, never the plant: "Topeka,
  # Dutch Housing" is Dutch Housing; a plant named for its town alone builds
  # under the manufacturer's own name.
  def brand
    name.to_s.include?(',') ? name.split(',', 2).last.strip : manufacturer&.name
  end
end
