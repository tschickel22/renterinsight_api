# frozen_string_literal: true

FactoryBot.define do
  factory :communication_event do
    association :communication
    
    event_type { 'sent' }
    occurred_at { Time.current }
    details { {} }
    
    trait :opened do
      event_type { 'opened' }
    end
    
    trait :clicked do
      event_type { 'clicked' }
    end
    
    trait :bounced do
      event_type { 'bounced' }
    end
    
    trait :failed do
      event_type { 'failed' }
    end
  end
end
