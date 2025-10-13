# frozen_string_literal: true

FactoryBot.define do
  factory :communication do
    association :communicable, factory: :lead
    
    direction { 'outbound' }
    channel { 'email' }
    status { 'pending' }
    subject { 'Test Subject' }
    body { 'Test body content' }
    from_address { 'sender@example.com' }
    to_address { 'recipient@example.com' }
    
    trait :email do
      channel { 'email' }
      subject { 'Email Subject' }
    end
    
    trait :sms do
      channel { 'sms' }
      subject { nil }
    end
    
    trait :inbound do
      direction { 'inbound' }
    end
    
    trait :outbound do
      direction { 'outbound' }
    end
    
    trait :pending do
      status { 'pending' }
    end
    
    trait :sent do
      status { 'sent' }
      sent_at { Time.current }
    end
    
    trait :delivered do
      status { 'delivered' }
      sent_at { 1.hour.ago }
      delivered_at { Time.current }
    end
    
    trait :failed do
      status { 'failed' }
      failed_at { Time.current }
      error_message { 'Test error' }
    end
  end
end
