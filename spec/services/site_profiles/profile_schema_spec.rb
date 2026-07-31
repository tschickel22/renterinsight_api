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

  describe 'placeholder values from the model' do
    # A real committed site shipped with primary_color "#unknown": the model
    # answered "unknown", the schema only checked it was a String, and the
    # backend helpfully prefixed a "#".
    it 'drops "unknown" rather than letting it become #unknown' do
      profile, = described_class.coerce(
        'brand' => { 'name' => 'Kept', 'colors' => { 'primary' => 'unknown', 'secondary' => '#059669' } }
      )

      expect(profile['brand']['colors']).to eq('secondary' => '#059669')
      expect(profile['brand']['name']).to eq('Kept')
    end

    # Placeholders are stripped earlier, so the warning path covers the other
    # way a colour goes wrong: a real word that is simply not a hex value.
    it 'warns when it drops a non-hex colour it did not recognise as a placeholder' do
      profile, warnings = described_class.coerce(
        'brand' => { 'colors' => { 'primary' => 'dark blue', 'secondary' => '#059669' } }
      )

      expect(profile['brand']['colors']).to eq('secondary' => '#059669')
      expect(warnings.join).to match(/dark blue/)
    end

    it 'removes the colors key entirely when none survive, so the template palette wins' do
      profile, = described_class.coerce('brand' => { 'colors' => { 'primary' => 'N/A' } })
      expect(profile['brand']).not_to have_key('colors')
    end

    it 'accepts hex in every common form' do
      profile, = described_class.coerce(
        'brand' => { 'colors' => { 'primary' => '#059669', 'secondary' => 'b91c1c', 'accent' => '#0a0' } }
      )
      expect(profile['brand']['colors'].keys).to contain_exactly('primary', 'secondary', 'accent')
    end

    it 'drops placeholder text from ordinary string fields too' do
      profile, = described_class.coerce(
        'brand' => { 'name' => 'Sunshine Homes', 'tagline' => 'not specified' },
        'contact' => { 'phone' => 'unknown', 'email' => 'sales@x.example' }
      )

      expect(profile['brand']).to eq('name' => 'Sunshine Homes')
      expect(profile['contact']).to eq('email' => 'sales@x.example')
    end

    it 'drops a placeholder font rather than setting it as the site font' do
      profile, = described_class.coerce('brand' => { 'fonts' => { 'heading' => 'unknown', 'body' => 'unknown' } })
      expect(profile['brand']).not_to have_key('fonts')
    end
  end

  describe '.from_manual' do
    # A prospect with no website has nothing to scan, and the in-app showcase
    # cannot be emailed to them — without this the only way to demo is creating
    # a real company and Website record.
    let(:built) do
      described_class.from_manual(
        business_name: 'Sunshine Homes',
        tagline: 'Colorado homes since 1992',
        primary_color: '#b91c1c',
        phone: '303-555-0100',
        headline: 'Your dream home awaits',
        subhead: 'Quality homes, honest pricing'
      )
    end

    it 'maps form fields onto the same shape a scan produces' do
      expect(built['brand']['name']).to eq('Sunshine Homes')
      expect(built['brand']['colors']['primary']).to eq('#b91c1c')
      expect(built['contact']['phone']).to eq('303-555-0100')
      expect(built['copy']['hero'].first['headline']).to eq('Your dream home awaits')
      expect(built['copy']['hero'].first['subhead']).to eq('Quality homes, honest pricing')
      expect(built['seo']['title']).to eq('Sunshine Homes')
    end

    it 'marks the profile as hand-entered so the model skips the URL requirement' do
      expect(built.dig('source', 'entered_manually')).to be(true)
    end

    it 'leaves blanks out rather than filling them with placeholder text' do
      thin = described_class.from_manual(business_name: 'Just A Name')
      expect(thin['copy']['hero']).to eq([])
      expect(thin['contact']).to eq({})
      expect(thin['brand']).to eq('name' => 'Just A Name')
    end

    it 'produces something the coercer accepts unchanged' do
      coerced, warnings = described_class.coerce(built)
      expect(warnings).to be_empty
      expect(coerced['brand']['name']).to eq('Sunshine Homes')
    end
  end
end
