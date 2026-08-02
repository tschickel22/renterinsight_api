# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ses::IdentityManager do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:domain) { company.company_domains.create!(hostname: "mail-#{SecureRandom.hex(3)}.example.com") }
  let(:client) { instance_double(Aws::SESV2::Client) }

  let(:tokens) { %w[tokenaaa tokenbbb tokenccc] }

  def dkim_attributes(status:, tokens: [])
    double(status: status, tokens: tokens)
  end

  def mail_from_attributes(domain_name:, status:)
    double(mail_from_domain: domain_name, mail_from_domain_status: status)
  end

  describe '#create_identity!' do
    before do
      allow(client).to receive(:create_email_identity)
        .and_return(double(dkim_attributes: dkim_attributes(status: 'PENDING', tokens: tokens)))
      allow(client).to receive(:put_email_identity_mail_from_attributes)
    end

    it 'stores the three DKIM tokens SES issues' do
      described_class.new(domain, client: client).create_identity!

      expect(domain.reload.ses_dkim_tokens).to eq(tokens)
      expect(domain.email_enabled).to be true
    end

    it 'leaves the domain unverified until SES confirms' do
      described_class.new(domain, client: client).create_identity!

      expect(domain.reload.email_verified_at).to be_nil
      expect(domain.email_verified?).to be false
      expect(domain.email_status).to eq('pending')
    end

    it 'configures a custom MAIL FROM subdomain that rejects on MX failure' do
      expect(client).to receive(:put_email_identity_mail_from_attributes).with(
        email_identity: domain.hostname,
        mail_from_domain: "mail.#{domain.hostname}",
        behavior_on_mx_failure: 'REJECT_MESSAGE'
      )

      described_class.new(domain, client: client).create_identity!

      expect(domain.reload.ses_mail_from_domain).to eq("mail.#{domain.hostname}")
    end

    it 'still records the identity when MAIL FROM setup fails' do
      allow(client).to receive(:put_email_identity_mail_from_attributes)
        .and_raise(Aws::SESV2::Errors::BadRequestException.new(nil, 'nope'))

      described_class.new(domain, client: client).create_identity!

      expect(domain.reload.ses_dkim_tokens).to eq(tokens)
    end

    it 'adopts an existing identity instead of failing' do
      allow(client).to receive(:create_email_identity)
        .and_raise(Aws::SESV2::Errors::AlreadyExistsException.new(nil, 'exists'))
      allow(client).to receive(:get_email_identity).and_return(
        double(
          dkim_attributes: dkim_attributes(status: 'SUCCESS', tokens: tokens),
          mail_from_attributes: mail_from_attributes(domain_name: "mail.#{domain.hostname}", status: 'SUCCESS')
        )
      )

      described_class.new(domain, client: client).create_identity!

      expect(domain.reload.ses_dkim_tokens).to eq(tokens)
      expect(domain.email_verified_at).to be_present
    end

    it 'raises a SesError on an SES service failure' do
      allow(client).to receive(:create_email_identity)
        .and_raise(Aws::SESV2::Errors::LimitExceededException.new(nil, 'too many identities'))

      expect { described_class.new(domain, client: client).create_identity! }
        .to raise_error(described_class::SesError, /too many identities/)
      expect(domain.reload.ses_error).to include('too many identities')
    end
  end

  describe '#refresh_status!' do
    before { domain.update!(email_enabled: true, ses_dkim_tokens: tokens) }

    it 'verifies the domain only when SES reports DKIM success' do
      allow(client).to receive(:get_email_identity).and_return(
        double(
          dkim_attributes: dkim_attributes(status: 'SUCCESS', tokens: tokens),
          mail_from_attributes: mail_from_attributes(domain_name: "mail.#{domain.hostname}", status: 'SUCCESS')
        )
      )

      described_class.new(domain, client: client).refresh_status!

      expect(domain.reload.email_verified?).to be true
      expect(domain.email_status).to eq('verified')
    end

    it 'does not verify while SES still reports pending' do
      allow(client).to receive(:get_email_identity).and_return(
        double(
          dkim_attributes: dkim_attributes(status: 'PENDING', tokens: tokens),
          mail_from_attributes: mail_from_attributes(domain_name: "mail.#{domain.hostname}", status: 'PENDING')
        )
      )

      described_class.new(domain, client: client).refresh_status!

      expect(domain.reload.email_verified?).to be false
    end

    it 'un-verifies a domain whose DKIM SES has since failed' do
      domain.update!(email_verified_at: 1.day.ago)
      allow(client).to receive(:get_email_identity).and_return(
        double(
          dkim_attributes: dkim_attributes(status: 'FAILED', tokens: tokens),
          mail_from_attributes: mail_from_attributes(domain_name: nil, status: nil)
        )
      )

      described_class.new(domain, client: client).refresh_status!

      expect(domain.reload.email_verified?).to be false
    end

    it 'keeps the stored tokens when SES returns none' do
      allow(client).to receive(:get_email_identity).and_return(
        double(
          dkim_attributes: dkim_attributes(status: 'PENDING', tokens: []),
          mail_from_attributes: mail_from_attributes(domain_name: nil, status: nil)
        )
      )

      described_class.new(domain, client: client).refresh_status!

      expect(domain.reload.ses_dkim_tokens).to eq(tokens)
    end

    it 'marks a deleted identity not found rather than raising' do
      allow(client).to receive(:get_email_identity)
        .and_raise(Aws::SESV2::Errors::NotFoundException.new(nil, 'gone'))

      described_class.new(domain, client: client).refresh_status!

      expect(domain.reload.ses_identity_status).to eq('NOT_FOUND')
      expect(domain.email_verified?).to be false
    end
  end

  describe 'DNS records shown to the tenant' do
    before do
      allow(client).to receive(:create_email_identity)
        .and_return(double(dkim_attributes: dkim_attributes(status: 'PENDING', tokens: tokens)))
      allow(client).to receive(:put_email_identity_mail_from_attributes)
      described_class.new(domain, client: client).create_identity!
      domain.reload
    end

    it 'lists one CNAME per DKIM token pointing at amazonses' do
      cnames = domain.email_dns_records.select { |r| r[:type] == 'CNAME' }

      expect(cnames.length).to eq(3)
      expect(cnames.first[:name]).to eq("#{tokens.first}._domainkey.#{domain.hostname}")
      expect(cnames.first[:value]).to eq("#{tokens.first}.dkim.amazonses.com")
      expect(cnames).to all(include(required: true))
    end

    it 'includes the MAIL FROM MX and SPF pair' do
      records = domain.email_dns_records

      expect(records.find { |r| r[:type] == 'MX' }[:name]).to eq("mail.#{domain.hostname}")
      expect(records.find { |r| r[:type] == 'TXT' }[:value]).to eq('v=spf1 include:amazonses.com ~all')
    end

    it 'returns nothing when email sending is not enabled' do
      domain.update!(email_enabled: false)

      expect(domain.email_dns_records).to eq([])
    end
  end
end
