# frozen_string_literal: true

require 'rails_helper'

# A location that buys from more than one Champion factory has one DIGS key
# per factory, so it needs one feed per key (Tom, 2026-11-10).
RSpec.describe ChampionLeadFeedConfig, type: :model do
  let(:company)  { create(:company) }
  let(:location) { company.locations.create!(name: 'Main Lot') }

  def feed(token, loc = location)
    company.champion_lead_feed_configs.create!(api_token: token, environment: 'production', location: loc)
  end

  it 'allows one feed per factory key at the same location' do
    feed('key-factory-a')
    expect { feed('key-factory-b') }.to change(described_class, :count).by(1)
  end

  it 'refuses the same key twice, which would import every lead twice' do
    feed('same-key')
    dup = company.champion_lead_feed_configs.build(api_token: 'same-key', environment: 'production', location: nil)
    expect(dup).not_to be_valid
    expect(dup.errors[:api_token].join).to include('already used')
  end

  it 'still saves sync results on an existing feed' do
    config = feed('key-a')
    expect { config.record_sync_success!(created: 2) }.not_to raise_error
    expect(config.reload.total_leads_synced).to eq(2)
  end

  describe 'choosing the key to accept or decline a lead' do
    let!(:factory_a) { feed('key-factory-a') }
    let!(:factory_b) { feed('key-factory-b') }
    let!(:company_wide) { feed('key-company', nil) }
    let(:lead) { create(:lead, company: company, location_id: location.id, champion_config_id: factory_b.id) }

    it 'uses the feed that brought the lead in, not the first feed at its location' do
      expect(Public::ChampionLeadActionsController.new.send(:find_config, lead)).to eq(factory_b)
    end

    it 'falls back to the location feed, then company-wide, when the lead has none' do
      lead.update_columns(champion_config_id: nil)
      expect(Public::ChampionLeadActionsController.new.send(:find_config, lead)).to eq(factory_a)
      lead.update_columns(location_id: nil)
      expect(Public::ChampionLeadActionsController.new.send(:find_config, lead)).to eq(company_wide)
    end
  end
end
