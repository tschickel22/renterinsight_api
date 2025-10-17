# frozen_string_literal: true

class Vehicle < ApplicationRecord
  belongs_to :company, optional: true

  # Validations
  validates :stock_number, presence: true, uniqueness: true
  validates :year, :make, :model, presence: true
  validates :status, inclusion: { in: %w[available sold pending reserved] }
  validates :condition, inclusion: { in: %w[new used] }

  # Scopes
  scope :active, -> { where(is_deleted: false) }
  scope :available, -> { active.where(status: 'available') }
  scope :by_year, ->(year) { where(year: year) }
  scope :by_make, ->(make) { where(make: make) }

  # Soft delete
  def soft_delete
    update(is_deleted: true, deleted_at: Time.current)
  end

  # Display name
  def display_name
    "#{year} #{make} #{model}#{trim.present? ? " #{trim}" : ''}"
  end
end
