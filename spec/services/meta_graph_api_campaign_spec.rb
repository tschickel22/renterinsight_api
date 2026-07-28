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

  # Regression: a campaign with no bid_strategy made Meta reject the *ad set*
  # with "Bid Amount Or Bid Constraints Required For Bid Strategy" — which is
  # why joining an existing campaign worked while creating one did not.
  it 'sets a bid strategy that needs no bid cap' do
    create

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
