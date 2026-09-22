# frozen_string_literal: true

require 'rails_helper'

# Campaign email never leaves through a connected Google account. Google's Gmail
# API policy does not permit bulk or marketing mail, and the grant we hold is
# gmail.send, for a rep's one to one correspondence with their own contacts.
#
# Deliberately narrow: one to one email keeps using Gmail, and Microsoft carries
# no equivalent restriction, so an Outlook mailbox on the dealer's own domain
# keeps sending campaigns while they get a sending domain verified.
RSpec.describe 'Campaign senders and Google accounts' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}", email: 'office@dealer.example') }
  let(:user) do
    User.create!(email: 'rep@dealer.example', first_name: 'R', last_name: 'P',
                 password: 'Pass1234!', company_id: company.id)
  end

  def campaign_for(identity_type = 'User', identity_id = nil)
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                     campaign_type: 'blast', channel: 'email', audience_mode: 'static',
                     from_identity_type: identity_type, from_identity_id: identity_id || user.id,
                     throttle_per_day: 500)
  end

  def verified_domain(hostname)
    company.company_domains.create!(
      hostname: hostname, email_enabled: true, email_verified_at: Time.current,
      ses_dkim_tokens: %w[a b c], ses_mail_from_domain: "mail.#{hostname}"
    )
  end

  def mailbox_for(provider:, address: nil)
    attrs = { company_id: company.id, user_id: user.id, provider: provider,
              email_address: address || user.email, is_active: true }
    if provider == 'smtp'
      attrs.merge!(smtp_host: 'smtp.dealer.example', smtp_username: 'rep',
                   smtp_password_encrypted: 'secret')
    end
    UserEmailConnection.create!(attrs)
  end

  it 'refuses a Gmail mailbox as a campaign sender' do
    mailbox_for(provider: 'oauth_gmail')

    expect(campaign_for.resolve_email_connection_for_step).to be_nil
  end

  it 'still allows an Outlook mailbox on the dealers own domain' do
    mailbox = mailbox_for(provider: 'oauth_outlook')

    expect(campaign_for.resolve_email_connection_for_step).to eq(mailbox)
  end

  it 'still allows a plain SMTP mailbox' do
    mailbox = mailbox_for(provider: 'smtp')

    expect(campaign_for.resolve_email_connection_for_step).to eq(mailbox)
  end

  # A dealer on Google Workspace who verifies their domain is unaffected: the
  # send goes out as their own address over SES and never touches Google.
  it 'lets a Gmail rep send once their sending domain is verified' do
    verified_domain('dealer.example')
    mailbox_for(provider: 'oauth_gmail')

    resolved = campaign_for.resolve_email_connection_for_step

    expect(resolved).to be_a(Ses::SendingIdentity)
    expect(resolved.email_address).to eq('rep@dealer.example')
  end

  it 'applies to a company-level Google mailbox too' do
    CompanyEmailConnection.create!(
      company_id: company.id, provider: 'oauth_gmail',
      email_address: 'office@dealer.example', is_active: true
    )

    expect(campaign_for('Company', company.id).resolve_email_connection_for_step).to be_nil
  end

  describe 'the central backstop in CommunicationService' do
    it 'refuses a campaign send resolved to Google by any other route' do
      lead = Lead.create!(company_id: company.id, first_name: 'A', last_name: 'B',
                          email: 'buyer@example.com')

      expect {
        CommunicationService.new.send_communication(
          communicable: lead, channel: 'email', to: 'buyer@example.com',
          subject: 'Hi', body: 'Body', category: 'campaign', provider: :oauth_google,
          skip_preference_check: true, skip_suppression_check: true
        )
      }.to raise_error(CommunicationService::Error, /cannot be sent through a connected Google account/i)
    end

    it 'leaves one to one email on Google alone' do
      lead = Lead.create!(company_id: company.id, first_name: 'A', last_name: 'B',
                          email: 'buyer@example.com')

      # The send still fails here (no real Google credentials in a spec), but it
      # must not be THIS guard that stops it: transactional mail on Gmail is the
      # whole point of the grant.
      error = begin
        CommunicationService.new.send_communication(
          communicable: lead, channel: 'email', to: 'buyer@example.com',
          subject: 'Hi', body: 'Body', category: 'transactional', provider: :oauth_google,
          skip_preference_check: true, skip_suppression_check: true
        )
        nil
      rescue StandardError => e
        e
      end

      expect(error&.message.to_s).not_to match(/connected Google account/i)
    end
  end
end
