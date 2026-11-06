# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmsRegistration::CampaignContent do
  let(:brand) do
    Struct.new(:name, :privacy_url, :terms_url, :support_email, keyword_init: true).new(
      name: 'DealerTide', privacy_url: 'https://www.dealertide.com/privacy-policy/',
      terms_url: 'https://www.dealertide.com/terms-of-use/', support_email: 'support@dealertide.com'
    )
  end

  describe 'the shared pool campaign' do
    subject(:content) { described_class.new(kind: 'pool', brand: brand, form_url: 'https://example.test/f/abc') }

    it 'has nothing a reviewer would reject' do
      expect(content.problems).to eq([])
    end

    it 'says who sends, who receives and why, and that nothing is marketing (30886)' do
      expect(content.description).to include('Renter Insight, LLC operates DealerTide', 'consumers who asked a dealership',
                                             'appointment', 'sends no marketing')
    end

    it 'quotes only the inquiry box as the consent for these texts (30913)' do
      expect(content.message_flow).to include(content.inquiry_consent, 'separate', 'does not enable any message')
      expect(content.message_flow).not_to include(content.marketing_consent)
    end

    it 'names the dealer in every sample and gives a HELP reply that names the sender' do
      expect(content.message_samples).to all(start_with('Summit Park Homes via DealerTide:'))
      expect(content.help_message).to include('DealerTide', 'support@dealertide.com', 'STOP')
      expect(content.twilio_attributes).to include('PrivacyPolicyUrl', 'TermsAndConditionsUrl')
    end
  end

  describe "a dealer's own campaign" do
    subject(:content) do
      described_class.new(kind: 'dealer', brand: brand, dealer_name: 'Easy Homesource', legal_name: 'EHS Holdings LLC')
    end

    it 'has nothing a reviewer would reject' do
      expect(content.problems).to eq([])
    end

    it 'covers marketing with its own, separate consent and a marketing sample' do
      expect(content.message_flow).to include(content.inquiry_consent, content.marketing_consent, 'second, separate box')
      expect(content.description).to include('EHS Holdings LLC, doing business as Easy Homesource', 'separately agreed to marketing')
      expect(content.message_samples.last).to include('open house', 'STOP')
    end

    it 'refuses to go without a dealer name' do
      expect(described_class.new(kind: 'dealer', brand: brand).problems).to include('no dealer name')
    end
  end

  it 'flags a consent sentence that folds marketing in' do
    stub_const('IntakeForm::DEFAULT_SMS_CONSENT_TEXT', 'Yes, {{company}} may text me about my inquiry and offers. Reply STOP or HELP. Msg rates apply. Not a condition of purchase.')
    expect(described_class.new(kind: 'pool', brand: brand).problems).to include('30913: inquiry consent mentions marketing')
  end
end
