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

  # Default: the MAIL FROM subdomain is free. Collision behaviour is covered separately.
  # Stubs Dns::Lookup rather than Resolv directly: stubbing the raw resolver is what let a
  # broken Resolv::DNS.open signature ship undetected.
  before { allow(Dns::Lookup).to receive(:resolve!).and_return([]) }

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
        mail_from_domain: "bounce.#{domain.hostname}",
        behavior_on_mx_failure: 'REJECT_MESSAGE'
      )

      described_class.new(domain, client: client).create_identity!

      expect(domain.reload.ses_mail_from_domain).to eq("bounce.#{domain.hostname}")
    end

    it 'still records the identity when MAIL FROM setup fails' do
      allow(client).to receive(:put_email_identity_mail_from_attributes)
        .and_raise(Aws::SESV2::Errors::BadRequestException.new(nil, 'nope'))

      described_class.new(domain, client: client).create_identity!

      expect(domain.reload.ses_dkim_tokens).to eq(tokens)
    end

    context 'when SES already has the identity' do
      # SES identities are account-level, so a domain registered from any environment
      # sharing the account comes back as AlreadyExists here.
      before do
        allow(client).to receive(:create_email_identity)
          .and_raise(Aws::SESV2::Errors::AlreadyExistsException.new(nil, 'exists'))
        allow(client).to receive(:get_email_identity).and_return(
          double(
            dkim_attributes: dkim_attributes(status: 'SUCCESS', tokens: tokens),
            mail_from_attributes: mail_from_attributes(domain_name: "bounce.#{domain.hostname}", status: 'SUCCESS')
          )
        )
      end

      it 'adopts it instead of failing' do
        described_class.new(domain, client: client).create_identity!

        expect(domain.reload.ses_dkim_tokens).to eq(tokens)
        expect(domain.email_verified_at).to be_present
      end

      # Regression guard. Adopting used to leave email_enabled false, and email_verified?
      # requires both, so a domain SES had fully verified read as pending forever.
      it 'enables sending, not just records the verification' do
        described_class.new(domain, client: client).create_identity!

        expect(domain.reload.email_enabled).to be true
        expect(domain.email_verified?).to be true
        expect(domain.email_status).to eq('verified')
      end

      it 'shows the DNS records, which are hidden while sending is disabled' do
        described_class.new(domain, client: client).create_identity!

        expect(domain.reload.email_dns_records).not_to be_empty
      end

      # Adopting skipped apply_mail_from! entirely, so an adopted identity verified with no
      # MAIL FROM and its Return-Path stayed amazonses.com. SPF then authenticated Amazon
      # rather than the tenant, quietly, because DMARC still passed on DKIM alignment.
      context 'and SES has no MAIL FROM on it' do
        before do
          allow(client).to receive(:get_email_identity).and_return(
            double(
              dkim_attributes: dkim_attributes(status: 'SUCCESS', tokens: tokens),
              mail_from_attributes: mail_from_attributes(domain_name: nil, status: nil)
            ),
            double(
              dkim_attributes: dkim_attributes(status: 'SUCCESS', tokens: tokens),
              mail_from_attributes: mail_from_attributes(domain_name: "bounce.#{domain.hostname}",
                                                         status: 'PENDING')
            )
          )
          allow(client).to receive(:put_email_identity_mail_from_attributes)
        end

        it 'applies one rather than leaving the identity without' do
          described_class.new(domain, client: client).create_identity!

          expect(client).to have_received(:put_email_identity_mail_from_attributes)
            .with(hash_including(email_identity: domain.hostname,
                                 mail_from_domain: "bounce.#{domain.hostname}"))
          expect(domain.reload.ses_mail_from_domain).to eq("bounce.#{domain.hostname}")
        end
      end
    end

    it 'raises a SesError on an SES service failure' do
      allow(client).to receive(:create_email_identity)
        .and_raise(Aws::SESV2::Errors::LimitExceededException.new(nil, 'too many identities'))

      expect { described_class.new(domain, client: client).create_identity! }
        .to raise_error(described_class::SesError, /too many identities/)
      expect(domain.reload.ses_error).to include('too many identities')
    end
  end

  # Regression guard. The MAIL FROM subdomain used to default to "mail", and
  # mail.dealertide.com already carries the inbound campaign reply MX. Following the
  # generated records would have replaced it and silently killed inbound replies. Dealers
  # commonly point mail.<domain> at webmail, so this is not specific to us.
  describe 'when the MAIL FROM subdomain already receives mail' do
    before do
      allow(client).to receive(:create_email_identity)
        .and_return(double(dkim_attributes: dkim_attributes(status: 'PENDING', tokens: tokens)))
      allow(client).to receive(:put_email_identity_mail_from_attributes)
      allow(Dns::Lookup).to receive(:resolve!).and_return(['mail.someoneelse.example'])
    end

    it 'refuses to claim the subdomain' do
      expect(client).not_to receive(:put_email_identity_mail_from_attributes)

      described_class.new(domain, client: client).create_identity!
    end

    it 'does not tell the tenant to publish records that would break their mail' do
      described_class.new(domain, client: client).create_identity!

      records = domain.reload.email_dns_records
      expect(records.map { |r| r[:type] }).to all(eq('CNAME'))
      expect(domain.ses_mail_from_domain).to be_nil
    end

    it 'still completes DKIM setup, which is what actually enables sending' do
      described_class.new(domain, client: client).create_identity!

      expect(domain.reload.ses_dkim_tokens).to eq(tokens)
      expect(domain.email_enabled).to be true
    end

    it 'treats a failed DNS lookup as occupied rather than assuming it is free' do
      allow(Dns::Lookup).to receive(:resolve!).and_raise(Resolv::ResolvError)
      expect(client).not_to receive(:put_email_identity_mail_from_attributes)

      described_class.new(domain, client: client).create_identity!
    end
  end

  # The repair entry point for domains that verified before this was wired up, driven by
  # bin/rails ses:domains:mail_from.
  describe '#ensure_mail_from!' do
    before { domain.update!(email_enabled: true, ses_dkim_tokens: tokens, email_verified_at: Time.current) }

    def ses_identity(mail_from:, status: nil)
      double(
        dkim_attributes: dkim_attributes(status: 'SUCCESS', tokens: tokens),
        mail_from_attributes: mail_from_attributes(domain_name: mail_from, status: status)
      )
    end

    it 'applies a MAIL FROM when SES has none' do
      allow(client).to receive(:get_email_identity).and_return(
        ses_identity(mail_from: nil),
        ses_identity(mail_from: "bounce.#{domain.hostname}", status: 'PENDING')
      )
      allow(client).to receive(:put_email_identity_mail_from_attributes)

      described_class.new(domain, client: client).ensure_mail_from!

      expect(domain.reload.ses_mail_from_domain).to eq("bounce.#{domain.hostname}")
    end

    # Asking SES first means a MAIL FROM we simply never recorded is adopted rather than
    # re-published, so running the repair over every domain stays cheap and safe.
    it 'adopts a MAIL FROM that SES has but we never recorded' do
      allow(client).to receive(:get_email_identity)
        .and_return(ses_identity(mail_from: "bounce.#{domain.hostname}", status: 'SUCCESS'))
      allow(client).to receive(:put_email_identity_mail_from_attributes)

      described_class.new(domain, client: client).ensure_mail_from!

      expect(client).not_to have_received(:put_email_identity_mail_from_attributes)
      expect(domain.reload.ses_mail_from_domain).to eq("bounce.#{domain.hostname}")
    end

    it 'never publishes over a subdomain that already receives mail' do
      allow(Dns::Lookup).to receive(:resolve!).and_return(['mx.example.com'])
      allow(client).to receive(:get_email_identity).and_return(ses_identity(mail_from: nil))
      allow(client).to receive(:put_email_identity_mail_from_attributes)

      described_class.new(domain, client: client).ensure_mail_from!

      expect(client).not_to have_received(:put_email_identity_mail_from_attributes)
      expect(domain.reload.ses_mail_from_domain).to be_nil
    end

    it 'leaves the domain verified rather than resetting it' do
      allow(client).to receive(:get_email_identity).and_return(
        ses_identity(mail_from: nil),
        ses_identity(mail_from: "bounce.#{domain.hostname}", status: 'PENDING')
      )
      allow(client).to receive(:put_email_identity_mail_from_attributes)

      described_class.new(domain, client: client).ensure_mail_from!

      expect(domain.reload.email_verified?).to be true
    end
  end

  describe '#refresh_status!' do
    before { domain.update!(email_enabled: true, ses_dkim_tokens: tokens) }

    it 'verifies the domain only when SES reports DKIM success' do
      allow(client).to receive(:get_email_identity).and_return(
        double(
          dkim_attributes: dkim_attributes(status: 'SUCCESS', tokens: tokens),
          mail_from_attributes: mail_from_attributes(domain_name: "bounce.#{domain.hostname}", status: 'SUCCESS')
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
          mail_from_attributes: mail_from_attributes(domain_name: "bounce.#{domain.hostname}", status: 'PENDING')
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

      expect(records.find { |r| r[:type] == 'MX' }[:name]).to eq("bounce.#{domain.hostname}")
      expect(records.find { |r| r[:type] == 'TXT' }[:value]).to eq('v=spf1 include:amazonses.com ~all')
    end

    it 'returns nothing when email sending is not enabled' do
      domain.update!(email_enabled: false)

      expect(domain.email_dns_records).to eq([])
    end
  end
end
