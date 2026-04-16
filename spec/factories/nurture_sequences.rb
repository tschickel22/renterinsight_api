# frozen_string_literal: true

FactoryBot.define do
  factory :nurture_sequence do
    sequence(:name) { |n| "Nurture Sequence #{n}" }
    association :company, factory: :company
  end
end
