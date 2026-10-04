# frozen_string_literal: true

# A factory a platform admin gave a dealer for TrueBuild. Only released
# factories can be given, and a buyer sees a factory's homes only while it is
# both given and released (Truebuild::DealerFactories). Backlog E64.
class DealerFactory < ApplicationRecord
  belongs_to :company
  belongs_to :factory
  belongs_to :added_by, class_name: 'User', optional: true

  validates :factory_id, uniqueness: { scope: :company_id }
  validate :factory_released, on: :create

  private

  def factory_released
    errors.add(:factory, 'is not released for TrueBuild yet') unless factory&.truebuild_released?
  end
end
