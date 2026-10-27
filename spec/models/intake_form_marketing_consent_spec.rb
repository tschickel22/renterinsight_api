# frozen_string_literal: true

require 'rails_helper'

RSpec.describe IntakeForm, 'marketing consent wording', type: :model do
  let(:company) { Company.create!(name: 'DealerTide App', industry: 'saas') }
  let(:form) { IntakeForm.create!(company_id: company.id, name: 'Demo request', schema: [], is_active: true) }

  it 'uses the standard wording for the industry, with the company name, until one is written' do
    expect(form.resolved_marketing_consent_text)
      .to eq('Yes, DealerTide App may email and text me about its products, updates and offers. I can unsubscribe at any time.')
    expect(form.as_json['marketing_consent']['default_text']).to include('{{company}}', 'products, updates')
  end

  it 'follows the company when its industry changes' do
    form
    company.update!(industry: 'manufactured_housing')
    expect(form.reload.resolved_marketing_consent_text).to include('about homes, offers and events')
  end

  it 'has wording for every industry, and plain wording for one it does not know' do
    expect(IntakeForm::DEFAULT_MARKETING_CONSENT_TEXTS.keys).to match_array(Company::INDUSTRIES)
    expect(IntakeForm.default_marketing_consent_text(nil)).to include('products, services and offers')
    expect(IntakeForm.default_marketing_consent_text('rv')).to include('about RVs')
  end

  it 'shows the dealer wording and moves to a new version when it changes' do
    form.update!(marketing_consent_text: 'Yes, {{company}} may contact me about my demo.')
    expect(form.resolved_marketing_consent_text).to eq('Yes, DealerTide App may contact me about my demo.')
    expect(form.marketing_consent_version).to eq('v2')
  end

  it 'keeps the version when the wording does not really change' do
    form.update!(marketing_consent_text: IntakeForm.default_marketing_consent_text('saas'))
    form.update!(name: 'Renamed')
    expect(form.reload.marketing_consent_version).to eq('v1')
  end

  it 'is not undone by the editor echoing the old version back' do
    form.update!(marketing_consent_text: 'New words', marketing_consent_version: 'v1')
    expect(form.marketing_consent_version).to eq('v2')
  end
end
