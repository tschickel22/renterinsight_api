# frozen_string_literal: true

require 'rails_helper'

RSpec.describe IntakeForm, 'marketing consent wording', type: :model do
  let(:company) { Company.create!(name: 'DealerTide App', industry: 'saas') }
  let(:form) { IntakeForm.create!(company_id: company.id, name: 'Demo request', schema: [], is_active: true) }

  it 'uses the standard wording with the company name until one is written' do
    expect(form.resolved_marketing_consent_text).to start_with('Yes, DealerTide App may email and text me')
  end

  it 'shows the dealer wording and moves to a new version when it changes' do
    form.update!(marketing_consent_text: 'Yes, {{company}} may contact me about my demo.')
    expect(form.resolved_marketing_consent_text).to eq('Yes, DealerTide App may contact me about my demo.')
    expect(form.marketing_consent_version).to eq('v2')
  end

  it 'keeps the version when the wording does not really change' do
    form.update!(marketing_consent_text: IntakeForm::DEFAULT_MARKETING_CONSENT_TEXT)
    form.update!(name: 'Renamed')
    expect(form.reload.marketing_consent_version).to eq('v1')
  end

  it 'is not undone by the editor echoing the old version back' do
    form.update!(marketing_consent_text: 'New words', marketing_consent_version: 'v1')
    expect(form.marketing_consent_version).to eq('v2')
  end
end
