# frozen_string_literal: true

FactoryBot.define do
  factory :workflow_rule do
    sequence(:name) { |n| "Workflow Rule #{n}" }
    entity_type { 'lead' }
    status { 'draft' }
    trigger { { 'event_type' => 'lead.created' } }
    conditions { {} }
    steps { { 'nodes' => [], 'edges' => [] } }
    association :company, factory: :company
  end
end
