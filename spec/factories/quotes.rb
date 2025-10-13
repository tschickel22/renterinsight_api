# frozen_string_literal: true

FactoryBot.define do
  factory :quote do
    sequence(:quote_number) { |n| "Q#{1000 + n}" }
    total { 1000.00 }
    status { 'draft' }
  end
end
