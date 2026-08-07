# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ReplyToAddressService do
  describe '.mail_domain' do
    it 'uses INBOUND_MAIL_DOMAIN when it is set' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('INBOUND_MAIL_DOMAIN').and_return('mail.dealertide.com')

      expect(described_class.mail_domain).to eq('mail.dealertide.com')
    end

    # The reply domain has to move with the brand. Hardcoding it is what left DealerTide
    # campaigns carrying a Renter Insight reply address after the rest of the kernel moved.
    it 'derives from the brand kernel when no ENV override is set' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('INBOUND_MAIL_DOMAIN').and_return(nil)
      allow(Brand).to receive(:current).with(company: nil)
                                       .and_return(instance_double(Brand, subdomain_root: 'dealertide.com'))

      expect(described_class.mail_domain).to eq('mail.dealertide.com')
    end

    it 'resolves the brand per company so a whitelabelled tenant gets its own domain' do
      company = Company.create!(name: "Co-#{SecureRandom.hex(3)}")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('INBOUND_MAIL_DOMAIN').and_return(nil)
      allow(Brand).to receive(:current).with(company: company)
                                       .and_return(instance_double(Brand, subdomain_root: 'dealerbrand.com'))

      expect(described_class.mail_domain(company: company)).to eq('mail.dealerbrand.com')
    end
  end

  describe '.campaign_address' do
    let(:send_record) { instance_double(CampaignSend, id: 4321) }

    it 'builds a token the inbound parser can route' do
      allow(described_class).to receive(:mail_domain).and_return('mail.dealertide.com')

      address = described_class.campaign_address(send_record)

      expect(address).to eq('reply+campaign-4321@mail.dealertide.com')
    end

    # The parser is what has to understand whatever this generates, so pin the round trip
    # rather than just the string shape.
    it 'produces an address the parser extracts the send id from' do
      allow(described_class).to receive(:mail_domain).and_return('mail.dealertide.com')

      address = described_class.campaign_address(send_record)
      token = InboundEmail::ParserService.new({}).send(:extract_token, address)

      expect(token).to eq(prefix: 'reply', token: 'campaign-4321')
    end

    it 'returns nil rather than an address naming no send' do
      expect(described_class.campaign_address(nil)).to be_nil
    end
  end
end
