# frozen_string_literal: true

require 'rails_helper'

# A rule condition that walks an association (the lead's source) used to fall
# through to the custom-field lookup and resolve to nil, so the condition never
# passed and the rule never ran.
RSpec.describe WorkflowEngine::ConditionEvaluator, type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:champion) { company.sources.create!(name: 'Champion Leads', is_active: true) }
  let(:website) { company.sources.create!(name: 'Website', is_active: true) }

  def lead_from(source)
    Lead.create!(company_id: company.id, source_id: source.id, first_name: 'A', last_name: 'B')
  end

  it "reads a field through the lead's source" do
    expect(described_class.resolve_field('source.name', lead_from(champion))).to eq('Champion Leads')
  end

  it 'passes a rule condition on the source name for a matching lead only' do
    conditions = [{ 'field' => 'source.name', 'operator' => 'equals', 'value' => 'Champion Leads' }]

    expect(described_class.evaluate(conditions, lead_from(champion))).to be true
    expect(described_class.evaluate(conditions, lead_from(website))).to be false
  end

  it 'still reads custom fields for names that are not columns or associations' do
    lead = lead_from(website)
    allow(WorkflowEngine::CustomFieldsAccess).to receive(:read).with(lead, 'next_appointment').and_return('2026-10-01')

    expect(described_class.resolve_field('next_appointment', lead)).to eq('2026-10-01')
  end
end
