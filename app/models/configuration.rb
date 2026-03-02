# frozen_string_literal: true

class Configuration < ApplicationRecord
  belongs_to :company
  belongs_to :floor_plan
  belongs_to :user, optional: true
  belongs_to :configurable, polymorphic: true, optional: true

  before_create :generate_public_token

  validates :status, inclusion: {
    in: %w[draft shared quoted ordered archived]
  }

  scope :for_company, ->(company) { where(company: company) }
  scope :by_status, ->(status) { where(status: status) }

  def selected_options
    return [] if selections.blank?
    FloorPlanOption.where(id: selections)
  end

  private

  def generate_public_token
    self.public_token ||= SecureRandom.urlsafe_base64(16)
  end
end
