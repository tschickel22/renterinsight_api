# frozen_string_literal: true

require 'rails_helper'

# Deals used to emit only created/updated/deleted, so nothing could react to a
# deal moving through the pipeline, and the seeded Deal Won / Deal Lost
# templates fired on every save. These events use the dealer's own stage keys;
# the pipeline below is deliberately not the default one.
RSpec.describe 'Deal stage workflow events', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:account) { Account.create!(company_id: company.id, name: 'Household') }

  before do
    Setting.set('Company', company.id, 'pipeline_stages', [
      { 'key' => 'new', 'name' => 'New', 'order' => 1, 'probability' => 10 },
      { 'key' => 'financing', 'name' => 'Financing', 'order' => 2, 'probability' => 60 },
      { 'key' => 'sold', 'name' => 'Sold', 'order' => 3, 'probability' => 100 },
      { 'key' => 'delivered', 'name' => 'Delivered', 'order' => 4, 'probability' => 100 },
      { 'key' => 'walked', 'name' => 'Walked', 'order' => 5, 'probability' => 0 }
    ])
  end

  def make_deal(stage: 'new')
    Deal.create!(company_id: company.id, account_id: account.id, name: 'Deal', stage: stage, value: 0)
  end

  def events(deal, type)
    WorkflowEvent.where(company_id: company.id, entity_type: 'Deal', entity_id: deal.id, event_type: type)
  end

  it "records a stage move with the dealer's own stage keys" do
    deal = make_deal

    deal.update!(stage: 'financing')

    event = events(deal, 'deal.status_changed').last
    expect(event.payload).to include('from' => 'new', 'to' => 'financing')
  end

  it 'records nothing when the stage did not change' do
    deal = make_deal

    deal.update!(name: 'Renamed')

    expect(events(deal, 'deal.status_changed')).to be_empty
  end

  it "fires deal.won on entering the dealer's won stage, and not again on the next won stage" do
    deal = make_deal

    deal.update!(stage: 'sold')
    deal.update!(stage: 'delivered')

    expect(events(deal, 'deal.won').count).to eq(1)
    expect(events(deal, 'deal.won').last.payload).to include('from' => 'new', 'to' => 'sold')
  end

  it "fires deal.lost on entering the dealer's lost stage" do
    deal = make_deal

    deal.update!(stage: 'walked')

    expect(events(deal, 'deal.lost').count).to eq(1)
    expect(events(deal, 'deal.won')).to be_empty
  end

  it 'does not fire deal.won for a deal created already sold' do
    deal = make_deal(stage: 'sold')

    expect(events(deal, 'deal.won')).to be_empty
  end

  it 'starts a rule only when the deal moves to the stage its condition names' do
    rule = WorkflowRule.create!(
      company_id: company.id, name: 'Financing docs', entity_type: 'Deal', status: 'active',
      trigger: { 'event_type' => 'deal.status_changed' },
      conditions: { 'type' => 'and', 'children' => [
        { 'field' => 'trigger.to', 'operator' => 'equals', 'value' => 'financing' }
      ] },
      steps: { 'nodes' => [{ 'id' => 'n1', 'type' => 'wait', 'config' => { 'duration' => 1 } }] }
    )
    to_financing = make_deal
    to_walked = make_deal

    to_financing.update!(stage: 'financing')
    to_walked.update!(stage: 'walked')
    DispatchWorkflowEventsJob.new.perform

    expect(WorkflowRun.where(workflow_rule_id: rule.id).pluck(:entity_id)).to eq([to_financing.id])
  end
end
