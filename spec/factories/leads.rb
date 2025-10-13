# frozen_string_literal: true

FactoryBot.define do
  factory :lead do
    sequence(:first_name) { |n| "FirstName#{n}" }
    sequence(:last_name) { |n| "LastName#{n}" }
    sequence(:email) { |n| "lead#{n}@example.com" }
    sequence(:phone) { |n| "555-000-#{n.to_s.rjust(4, '0')}" }
    status { 'new' }
    
    # Create associated company and source if needed
    association :company, factory: :company
    association :source, factory: :source
  end
end
