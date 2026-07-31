# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::ProfileSchema do
  describe '.coerce' do
    it 'keeps a well-formed profile intact' do
      profile, warnings = described_class.coerce(
        'brand' => { 'name' => 'Sunshine Homes', 'colors' => { 'primary' => '#059669' } },
        'contact' => { 'phone' => '303-555-0100' },
        'copy' => {
          'hero' => [{ 'headline' => 'Your Dream Home Awaits', 'subhead' => 'Since 1992' }],
          'faq' => [{ 'question' => 'Do you finance?', 'answer' => 'Yes.' }]
        },
        'seo' => { 'title' => 'Sunshine Homes', 'keywords' => %w[homes denver] }
      )

      expect(warnings).to be_empty
      expect(profile['brand']['name']).to eq('Sunshine Homes')
      expect(profile['brand']['colors']['primary']).to eq('#059669')
      expect(profile['copy']['hero'].first['headline']).to eq('Your Dream Home Awaits')
      expect(profile['seo']['keywords']).to eq(%w[homes denver])
      expect(profile['schema_version']).to eq(described_class::VERSION)
    end

    # "Repair, never raise" — a thin profile still projects into nine templates;
    # an exception means the admin waited three minutes for nothing.
    it 'survives a malformed section instead of raising' do
      profile, warnings = described_class.coerce(
        'copy' => { 'testimonials' => 'we love them' },
        'brand' => { 'name' => 'Kept' }
      )

      expect(profile['copy']['testimonials']).to eq([])
      expect(profile['brand']['name']).to eq('Kept')
      expect(warnings.join).to match(/testimonials/)
    end

    it 'drops unknown keys inside a section but keeps the known ones' do
      profile, = described_class.coerce(
        'copy' => { 'faq' => [{ 'question' => 'Q', 'answer' => 'A', 'sentiment' => 'positive' }] }
      )

      expect(profile['copy']['faq'].first).to eq('question' => 'Q', 'answer' => 'A')
    end

    it 'reports unknown top-level keys rather than silently ignoring them' do
      _profile, warnings = described_class.coerce('blocks' => [], 'pages' => [])
      expect(warnings.join).to match(/blocks/).and match(/pages/)
    end

    it 'drops non-hash entries in a section array' do
      profile, = described_class.coerce(
        'copy' => { 'services' => [{ 'title' => 'Delivery' }, 'setup', nil, 42] }
      )
      expect(profile['copy']['services']).to eq([{ 'title' => 'Delivery' }])
    end

    it 'caps runaway sections' do
      items = Array.new(50) { |i| { 'question' => "Q#{i}", 'answer' => 'A' } }
      profile, = described_class.coerce('copy' => { 'faq' => items })
      expect(profile['copy']['faq'].size).to eq(described_class::MAX_ITEMS_PER_SECTION)
    end

    it 'returns a usable empty profile for junk input' do
      [nil, 'nope', [], 42].each do |junk|
        profile, = described_class.coerce(junk)
        expect(profile['copy'].keys).to match_array(described_class::COPY_SECTIONS.keys)
        expect(profile['schema_version']).to eq(described_class::VERSION)
      end
    end

    it 'ignores non-string values where strings are required' do
      profile, = described_class.coerce('brand' => { 'name' => { 'nested' => 'x' }, 'tagline' => 'ok' })
      expect(profile['brand']).to eq('tagline' => 'ok')
    end
  end

  describe '.prompt_contract' do
    it 'forbids inventing content and forbids emitting blocks' do
      contract = described_class.prompt_contract
      expect(contract).to match(/never invent/i)
      expect(contract).to match(/do not emit page blocks/i)
    end

    it 'names every section the coercer knows about' do
      contract = described_class.prompt_contract
      described_class::COPY_SECTIONS.each_key do |section|
        expect(contract).to include(section)
      end
    end
  end
end
