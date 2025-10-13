# frozen_string_literal: true

FactoryBot.define do
  factory :source do
    sequence(:name) { |n| "Source #{n}" }
    source_type { 'web' }
  end
end
