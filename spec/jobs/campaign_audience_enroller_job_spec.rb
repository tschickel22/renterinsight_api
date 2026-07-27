# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CampaignAudienceEnrollerJob do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let!(:lead)   { Lead.create!(company: company, source: source, first_name: 'A', last_name: '1', email: "a-#{SecureRandom.hex(3)}@x.com") }

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'D',
                         campaign_type: 'blast', channel: 'email', audience_mode: 'dynamic', status: 'running',
                         from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi',
                             body_blocks: [{ 'type' => 'text', 'html' => 'a' }], wait_days: 0, wait_hours: 0)
    c.create_campaign_audience!(source_type: 'Lead', filter_tree: {}, estimated_count: 0)
    c
  end

  # Use a real cache store so the dedupe-flag assertions are meaningful (the
  # test env default is often the null store, where reads are always nil).
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }
  before { allow(Rails).to receive(:cache).and_return(cache_store) }

  it 'clears the dynamic-refresh dedupe flag so a straggler tag can re-enqueue' do
    key = "campaigns:dynamic_refresh:#{campaign.id}"
    Rails.cache.write(key, true, expires_in: 15.seconds)
    described_class.perform_now(campaign.id)
    expect(Rails.cache.read(key)).to be_nil
  end

  it 'enrolls matching recipients for a running campaign' do
    expect { described_class.perform_now(campaign.id) }
      .to change { campaign.campaign_enrollments.count }.from(0).to(1)
  end

  it 'does nothing for a non-running campaign' do
    campaign.update!(status: 'paused')
    expect { described_class.perform_now(campaign.id) }
      .not_to change { campaign.campaign_enrollments.count }
  end
end
