# frozen_string_literal: true

require 'rails_helper'

# Stored deal probabilities follow the company's current stage settings, so the
# forecast and the probability sort agree with the % the pipeline shows.
RSpec.describe Deals::ProbabilitySync do
  let(:company) { create(:company) }
  let(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let(:account) { company.accounts.create!(name: 'Buyer') }

  def deal(stage, **attrs)
    company.deals.create!(name: "D #{stage}", location: location, account: account, stage: stage, **attrs)
  end

  def save_stages(overrides)
    stages = Company::DEFAULT_PIPELINE_STAGES.map do |s|
      s.merge('probability' => overrides.fetch(s['key'], Company::DEFAULT_STAGE_PROBABILITIES[s['key']]))
    end
    Setting.set('Company', company.id, 'pipeline_stages', stages)
  end

  it 'rewrites stale probabilities from the current stage %' do
    proposal = deal('proposal')
    negotiation = deal('negotiation')
    expect(proposal.probability).to eq(60)

    save_stages('proposal' => 45, 'negotiation' => 90)

    expect(described_class.new(company).call).to eq(2)
    expect(proposal.reload.probability).to eq(45)
    expect(negotiation.reload.probability).to eq(90)
  end

  it 'is idempotent' do
    deal('proposal')
    save_stages('proposal' => 45)
    described_class.new(company).call
    expect(described_class.new(company).call).to eq(0)
  end

  it 'leaves deals whose stage the pipeline does not have alone' do
    orphan = deal('proposal')
    orphan.update_columns(stage: 'gone_stage', probability: 33)
    save_stages('proposal' => 45)

    described_class.new(company).call
    expect(orphan.reload.probability).to eq(33)
  end

  it 'skips deleted deals and other companies' do
    deleted = deal('proposal')
    deleted.update_columns(deleted_at: Time.current)
    other_company = create(:company)
    other_loc = other_company.locations.first || other_company.locations.create!(name: 'Main')
    other = other_company.deals.create!(name: 'Other', location: other_loc,
                                        account: other_company.accounts.create!(name: 'B'), stage: 'proposal')
    save_stages('proposal' => 45)

    described_class.new(company).call
    expect(deleted.reload.probability).to eq(60)
    expect(other.reload.probability).to eq(60)
  end

  it 'fills stale values for a company still on the default pipeline' do
    d = deal('proposal')
    d.update_columns(probability: 5)
    described_class.new(company).call
    expect(d.reload.probability).to eq(60)
  end

  it 'leaves updated_at alone' do
    d = deal('proposal')
    d.update_columns(updated_at: 2.days.ago.change(usec: 0))
    before = d.reload.updated_at
    save_stages('proposal' => 45)
    described_class.new(company).call
    expect(d.reload.updated_at).to eq(before)
  end
end
