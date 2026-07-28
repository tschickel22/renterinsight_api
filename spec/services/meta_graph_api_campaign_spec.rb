# frozen_string_literal: true

require 'rails_helper'

# Regression: the Ad Builder puts the budget on the ad set, not the campaign.
# Meta then rejects campaign creation outright with "Must specify True or False
# in is_adset_budget_sharing_enabled field" unless we answer that question.
RSpec.describe MetaGraphApi, '.create_campaign' do
  let(:posted) { [] }

  before do
    allow(described_class).to receive(:post) do |path, token, **params|
      posted << { path: path, token: token, params: params }
      { 'id' => 'c1' }
    end
  end

  def create(**overrides)
    described_class.create_campaign(
      '111', 'TOKEN',
      **{ name: 'Ad', objective: 'OUTCOME_TRAFFIC' }.merge(overrides)
    )
  end

  # bid_strategy and budget have to live at the same level. On a campaign with
  # no budget Meta answers "No Budget for Campaign — add a budget to edit the
  # bid strategy", so with ad-set budgets the strategy belongs on the ad set.
  it 'omits the bid strategy when the campaign has no budget' do
    create

    expect(posted.last[:params]).not_to have_key(:bid_strategy)
  end

  it 'sets the bid strategy alongside a campaign-level budget' do
    create(daily_budget_cents: 1500)

    expect(posted.last[:params][:bid_strategy]).to eq('LOWEST_COST_WITHOUT_CAP')
  end

  it 'declares ad-set budget sharing when the campaign carries no budget' do
    create

    expect(posted.last[:params][:is_adset_budget_sharing_enabled]).to be(false)
    expect(posted.last[:params]).not_to have_key(:daily_budget)
  end

  it 'omits the flag when the budget is on the campaign instead' do
    create(daily_budget_cents: 700)

    expect(posted.last[:params][:daily_budget]).to eq(700)
    expect(posted.last[:params]).not_to have_key(:is_adset_budget_sharing_enabled)
  end

  it 'serialises special ad categories as JSON' do
    create(special_ad_categories: ['HOUSING'])

    expect(posted.last[:params][:special_ad_categories]).to eq('["HOUSING"]')
  end

  it 'sends an empty category list when the ad is not a regulated vertical' do
    create(special_ad_categories: [])

    expect(posted.last[:params][:special_ad_categories]).to eq('[]')
  end
end

# The wizard's budget is an ad-set budget, so the bid strategy rides with it —
# without one Meta rejects the ad set for missing bid constraints.
RSpec.describe MetaGraphApi, '.create_ad_set' do
  let(:posted) { [] }

  before do
    allow(described_class).to receive(:post) do |path, token, **params|
      posted << { path: path, params: params }
      { 'id' => 'as1' }
    end
  end

  def create(**overrides)
    described_class.create_ad_set(
      '111', 'TOKEN',
      **{ campaign_id: 'c1', name: 'AdSet', daily_budget_cents: 1500,
          targeting: { age_min: 25 } }.merge(overrides)
    )
  end

  it 'carries the bid strategy next to the ad-set budget' do
    create

    expect(posted.last[:params][:bid_strategy]).to eq('LOWEST_COST_WITHOUT_CAP')
    expect(posted.last[:params][:daily_budget]).to eq(1500)
  end

  it 'sends an end time only when one is given' do
    create
    expect(posted.last[:params]).not_to have_key(:end_time)

    create(end_time: '2026-08-01T00:00:00Z')
    expect(posted.last[:params][:end_time]).to eq('2026-08-01T00:00:00Z')
  end
end
