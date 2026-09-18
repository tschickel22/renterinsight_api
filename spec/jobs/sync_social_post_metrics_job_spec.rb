# frozen_string_literal: true

require 'rails_helper'

# Meta retired every per-post reach and impressions metric, and a retired name
# rejects the whole insights call. Asking for post_impressions alongside
# post_clicks meant clicks never arrived either.
RSpec.describe SyncSocialPostMetricsJob do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let!(:integration) do
    company.facebook_integrations.create!(page_id: 'page-1', page_name: 'Test Page',
                                          page_access_token: 'PAGE-TOKEN', status: 'active')
  end
  let!(:post) do
    company.social_posts.create!(platform: 'facebook', status: 'published', caption: 'Hi',
                                 external_post_id: 'page-1_900', published_at: 1.day.ago)
  end

  before do
    allow(MetaAppReview).to receive(:awaiting).and_return([])
    allow(MetaGraphApi).to receive(:get_post_basic_metrics).and_return(
      'likes' => { 'summary' => { 'total_count' => 3 } },
      'comments' => { 'summary' => { 'total_count' => 2 } },
      'shares' => { 'count' => 1 }
    )
  end

  it 'asks only for post_clicks and records engagement and clicks' do
    expect(MetaGraphApi).to receive(:get).with('/page-1_900/insights', 'PAGE-TOKEN', metric: 'post_clicks')
      .and_return('data' => [{ 'name' => 'post_clicks', 'period' => 'lifetime', 'values' => [{ 'value' => 7 }] }])

    described_class.perform_now

    post.reload
    expect(post.engagement_count).to eq(6)
    expect(post.link_clicks).to eq(7)
    expect(post.reach).to be_nil
    expect(post.impressions).to be_nil
  end

  it 'still records engagement when clicks are refused' do
    allow(MetaGraphApi).to receive(:get).and_raise(MetaGraphApi::Error.new('(#100) bad metric', code: 100))

    described_class.perform_now

    post.reload
    expect(post.engagement_count).to eq(6)
    expect(post.link_clicks).to be_nil
  end
end
