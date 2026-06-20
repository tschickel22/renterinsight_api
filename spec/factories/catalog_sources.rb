FactoryBot.define do
  factory :catalog_source do
    sequence(:name) { |n| "Catalog Source #{n}" }
    adapter_type { 'manufacturedhomes_platform' }
    base_url { 'https://example-homes.com' }
    sequence(:manufacturer_id) { |n| (2000 + n).to_s }
    config { {} }
    enabled { false }
    schedule { 'nightly' }
    extraction_threshold { 0.80 }
    last_run_status { 'never_run' }
  end

  factory :scrape_run do
    association :catalog_source
    status { 'success' }
    trigger { 'manual' }
    started_at { Time.current - 60 }
    finished_at { Time.current }
    field_extraction_rates { {} }
    degraded { false }
    error_log { [] }
  end

  factory :dealer_catalog_subscription do
    association :company
    association :catalog_source
    enabled { true }
  end
end
