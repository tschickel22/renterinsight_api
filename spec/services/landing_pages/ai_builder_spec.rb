# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LandingPages::AiBuilder do
  let(:company) { Company.create!(name: "Ai-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:brief) { Marketing::Brief.new(company: company, user: user, prompt: 'Spring sale, $0 down') }

  let(:model_json) do
    {
      'profile' => {
        'brand' => { 'name' => 'Summit Park Homes' },
        'contact' => { 'phone' => '(303) 555-0000' },
        'copy' => { 'hero' => [{ 'headline' => 'Spring Sale', 'subhead' => '$0 down through March' }] },
        'seo' => { 'title' => 'Spring Sale' }
      },
      'form_fields' => [
        { 'name' => 'First Name', 'label' => 'First Name', 'type' => 'text', 'required' => true },
        { 'name' => 'email', 'label' => 'Email', 'type' => 'email', 'required' => true }
      ],
      'layout_hint' => 'lp-offer-focus'
    }
  end

  def stub_model(json = model_json, text: nil)
    allow_any_instance_of(described_class).to receive(:call_claude).and_return(
      text: text || json.to_json,
      model_version: 'claude-test', input_tokens: 100, output_tokens: 200
    )
  end

  before { stub_model }

  describe '#generate' do
    it 'returns coerced profile sections, form fields and a layout hint' do
      result = described_class.new(company: company, user: user).generate(brief: brief)

      expect(result[:profile].dig('copy', 'hero', 0, 'headline')).to eq('Spring Sale')
      expect(result[:layout_hint]).to eq('lp-offer-focus')
      expect(result[:form_fields].map { |f| f['name'] }).to include('email')
    end

    # Sections, not blocks — that is what lets the output project into layouts
    # that do not exist yet, using the projection that already exists.
    it 'emits profile sections rather than page blocks' do
      result = described_class.new(company: company).generate(brief: brief)

      expect(result[:profile]).to have_key('copy')
      expect(result[:profile]).not_to have_key('blocks')
      expect(result[:profile]['schema_version']).to eq(SiteProfiles::ProfileSchema::VERSION)
    end

    it 'requires a brief' do
      expect { described_class.new(company: company).generate(brief: nil) }
        .to raise_error(described_class::GenerationError, /brief is required/i)
    end

    it 'raises a clear error when the model does not return JSON' do
      stub_model(nil, text: 'Sure! Here is your landing page:')

      expect { described_class.new(company: company).generate(brief: brief) }
        .to raise_error(described_class::GenerationError, /not JSON/i)
    end
  end

  describe 'form fields' do
    # A lead with no way to reach them is not a lead.
    it 'adds an email field when the model omitted every contact field' do
      stub_model(model_json.merge('form_fields' => [
        { 'name' => 'notes', 'label' => 'Notes', 'type' => 'textarea' }
      ]))

      fields = described_class.new(company: company).generate(brief: brief)[:form_fields]
      expect(fields.map { |f| f['type'] }).to include('email')
    end

    it 'normalises field names and rejects unknown types' do
      stub_model(model_json.merge('form_fields' => [
        { 'name' => 'First Name', 'label' => 'First', 'type' => 'nuclear' },
        { 'name' => 'email', 'type' => 'email' }
      ]))

      fields = described_class.new(company: company).generate(brief: brief)[:form_fields]
      expect(fields.first['name']).to eq('first_name')
      expect(fields.first['type']).to eq('text')
    end

    # Every field costs conversions, and a model asked for a form will happily
    # produce fifteen.
    it 'caps the form at eight fields' do
      many = Array.new(20) { |i| { 'name' => "field_#{i}", 'type' => 'text' } }
      stub_model(model_json.merge('form_fields' => many))

      expect(described_class.new(company: company).generate(brief: brief)[:form_fields].size).to be <= 9
    end

    it 'drops fields with no name' do
      stub_model(model_json.merge('form_fields' => [{ 'label' => 'Nameless', 'type' => 'text' }]))

      fields = described_class.new(company: company).generate(brief: brief)[:form_fields]
      expect(fields.map { |f| f['name'] }).to eq(['email'])
    end
  end

  describe 'grounding' do
    let(:profile_record) do
      SiteContentProfile.create!(
        company: company, source_url: 'https://example.com', status: 'ready',
        profile: {
          'brand' => { 'name' => 'Real Dealer Name' },
          'contact' => { 'phone' => '(720) 999-1234', 'email' => 'real@dealer.example' }
        }
      )
    end
    let(:grounded_brief) do
      Marketing::Brief.new(company: company, user: user, prompt: 'Spring sale',
                           site_content_profile: profile_record)
    end

    # Inventing a phone number on a live landing page is a serious problem,
    # not a cosmetic one.
    it 'lets scanned contact details win over generated ones' do
      result = described_class.new(company: company).generate(brief: grounded_brief)

      expect(result[:profile]['contact']['phone']).to eq('(720) 999-1234')
      expect(result[:profile]['contact']['email']).to eq('real@dealer.example')
    end

    it 'lets the scanned brand name win' do
      result = described_class.new(company: company).generate(brief: grounded_brief)
      expect(result[:profile]['brand']['name']).to eq('Real Dealer Name')
    end

    it 'keeps generated content when there is nothing to ground it with' do
      result = described_class.new(company: company).generate(brief: brief)
      expect(result[:profile]['contact']['phone']).to eq('(303) 555-0000')
    end
  end

  describe 'metering' do
    it 'logs usage against the landing page feature' do
      expect { described_class.new(company: company, user: user).generate(brief: brief) }
        .to change { AiQueryLog.where(company_id: company.id, feature: described_class::FEATURE).count }.by(1)
    end

    it 'raises once the monthly credit is spent' do
      stub_const("#{described_class}::DEFAULT_MONTHLY_CREDIT", 1)
      described_class.new(company: company, user: user).generate(brief: brief)

      expect { described_class.new(company: company, user: user).generate(brief: brief) }
        .to raise_error(described_class::CreditLimitError, /credit limit/i)
    end

    # Metering must never cost the generation the user already paid for.
    it 'still returns the page when logging fails' do
      allow(AiQueryLog).to receive(:create!).and_raise(StandardError, 'log table gone')

      result = described_class.new(company: company, user: user).generate(brief: brief)
      expect(result[:profile]).to be_present
    end
  end

end
