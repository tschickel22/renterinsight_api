# frozen_string_literal: true

FactoryBot.define do
  factory :buyer_portal_access do
    association :buyer, factory: :lead
    sequence(:email) { |n| "buyer#{n}@example.com" }
    password { 'Password123!' }
    password_confirmation { 'Password123!' }
    portal_enabled { true }
    email_opt_in { true }
    sms_opt_in { true }
    marketing_opt_in { false }
    login_count { 0 }
    preference_history { [] }

    trait :with_reset_token do
      reset_token { SecureRandom.urlsafe_base64(32) }
      reset_token_expires_at { 1.hour.from_now }
    end

    trait :with_expired_reset_token do
      reset_token { SecureRandom.urlsafe_base64(32) }
      reset_token_expires_at { 1.hour.ago }
    end

    trait :with_login_token do
      login_token { SecureRandom.urlsafe_base64(32) }
      login_token_expires_at { 15.minutes.from_now }
    end

    trait :with_expired_login_token do
      login_token { SecureRandom.urlsafe_base64(32) }
      login_token_expires_at { 16.minutes.ago }
    end

    trait :disabled do
      portal_enabled { false }
    end

    trait :with_login_history do
      last_login_at { 1.day.ago }
      login_count { 5 }
      last_login_ip { '192.168.1.100' }
    end

    trait :opted_out do
      email_opt_in { false }
      sms_opt_in { false }
      marketing_opt_in { false }
    end
  end
end
