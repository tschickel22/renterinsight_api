# frozen_string_literal: true

require 'rails_helper'

RSpec.describe IntakeForm, 'marketing consent wording', type: :model do
  let(:company) { Company.create!(name: 'DealerTide App', industry: 'saas') }
  let(:form) { IntakeForm.create!(company_id: company.id, name: 'Demo request', schema: [], is_active: true) }

  it 'uses the standard wording for the industry, with the company name, until one is written' do
    expect(form.resolved_marketing_consent_text)
      .to eq("Yes, DealerTide App may email and text me about its products, updates and offers, sent through #{Brand.current.name}. " \
             'Message frequency varies. Message and data rates may apply. Reply STOP to opt out of texts or HELP for help. ' \
             'I can unsubscribe from email at any time. Consent is not a condition of purchase.')
    expect(form.as_json['marketing_consent']['default_text']).to include('{{company}}', 'products, updates')
  end

  it 'follows the company when its industry changes' do
    form
    company.update!(industry: 'manufactured_housing')
    expect(form.reload.resolved_marketing_consent_text).to include('about my inquiry, homes, appointments and offers')
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

  it 'carries the texting disclosures carriers check for, and links the platform policies' do
    company.update!(industry: 'manufactured_housing')
    text = form.reload.resolved_marketing_consent_text
    expect(text).to include("sent through #{Brand.current.name}", 'Message and data rates may apply',
                            'Reply STOP', 'HELP', 'not a condition of purchase')
    expect(text).not_to include('{{')
    consent = form.as_json['marketing_consent']
    expect(consent['privacy_url']).to eq(Brand.current.privacy_url)
    expect(consent['terms_url']).to eq(Brand.current.terms_url)
    expect(form.public_as_json['marketing_consent'].keys).to include('privacy_url', 'terms_url')
  end

  it 'is not undone by the editor echoing the old version back' do
    form.update!(marketing_consent_text: 'New words', marketing_consent_version: 'v1')
    expect(form.marketing_consent_version).to eq('v2')
  end
end
