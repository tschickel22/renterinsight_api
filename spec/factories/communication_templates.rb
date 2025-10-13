# frozen_string_literal: true

FactoryBot.define do
  factory :communication_template do
    sequence(:name) { |n| "Template #{n}" }
    channel { 'email' }
    subject_template { 'Subject: {{ variable }}' }
    body_template { 'Body: {{ variable }}' }
    category { 'transactional' }
    active { true }
    
    trait :email do
      channel { 'email' }
      subject_template { 'Email Subject: {{ lead.first_name }}' }
      body_template { 'Email Body: Hello {{ lead.first_name }}' }
    end
    
    trait :sms do
      channel { 'sms' }
      subject_template { nil }
      body_template { 'SMS: Hi {{ lead.first_name }}' }
    end
    
    trait :inactive do
      active { false }
    end
  end
end
