# frozen_string_literal: true

require 'rails_helper'

# Runs against real records. The previous version stubbed every relation the
# service touched, and the stubs drifted from the queries until four of these
# failed on code that worked.
RSpec.describe Knowledge::SmartSearchService do
  let!(:leads) do
    Knowledge::Module.create!(key: 'leads', name: 'Leads', route: '/crm', description: 'Prospects and inquiries', is_active: true)
  end
  let!(:create_feature) do
    leads.features.create!(key: 'create', name: 'Create Lead', route: '/crm', ui_selector: '[data-tour="add-button"]')
  end
  let!(:article) do
    Knowledge::Article.create!(knowledge_module: leads, title: 'Working your leads', slug: 'working-leads',
                               content: 'How to follow up with prospects', is_published: true)
  end

  before do
    Knowledge::IntentPattern.create!(pattern: '\b(create|add|new)\b.*\blead', intent_type: 'create', entity_key: 'leads', priority: 10)
  end

  def search(q, user: nil)
    described_class.new(q, user: user).search
  end

  it 'returns empty for a blank query without writing analytics' do
    expect { expect(search('')).to eq([]) }.not_to change(Knowledge::Search, :count)
  end

  it 'returns a navigate result for a confident intent and entity' do
    result = search('how do I create a lead').first
    expect(result).to include(type: 'navigate', module: 'leads', feature: 'create', route: '/crm')
  end

  it 'finds published articles by their words' do
    expect(search('follow up prospects').map { |r| r[:slug] }).to include('working-leads')
  end

  it 'resolves a bare synonym through the alias table' do
    Knowledge::EntityAlias.create!(alias_name: 'prospects', canonical_key: 'leads', entity_type: 'module')
    expect(search('prospects').first).to include(type: 'navigate', module: 'leads')
  end

  it 'logs a search that found nothing with a result count of zero' do
    results = search('zzqx gibberish')

    expect(results.first[:source]).to eq('fallback')
    expect(Knowledge::Search.last).to have_attributes(query: 'zzqx gibberish', result_count: 0)
  end

  it 'offers an approved tour even when unapproved ones match first, with the brand filled in' do
    3.times { |i| Tour.create!(key: "draft-#{i}", name: "Walkthrough draft #{i}", trigger_type: 'manual', position: i) }
    Tour.create!(key: 'ok', name: 'Walkthrough of {{brand}}', trigger_type: 'manual', position: 9, approved_at: Time.current)

    titles = search('walkthrough').select { |r| r[:type] == 'tour' }.map { |r| r[:title] }
    expect(titles).to eq(["Walkthrough of #{Brand.current.name}"])
  end

  describe 'tours while paused' do
    let!(:tour) { Tour.create!(key: 'lead-tour', name: 'Leads walkthrough', knowledge_module: leads, trigger_type: 'manual', approved_at: Time.current) }

    before { PlatformSetting.tours_paused = true }
    after  { PlatformSetting.tours_paused = false }

    it 'leaves them out for dealers' do
      expect(search('leads walkthrough').map { |r| r[:type] }).not_to include('tour')
    end

    it 'still offers them to platform admins' do
      admin = User.new(role: 'platform_admin')
      expect(search('leads walkthrough', user: admin).map { |r| r[:type] }).to include('tour')
    end
  end
end
