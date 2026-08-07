# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Campaign SES sending domain routing' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}", email: 'office@dealer.example') }
  let(:user) do
    User.create!(email: 'rep@dealer.example', first_name: 'R', last_name: 'P',
                 password: 'Pass1234!', company_id: company.id)
  end

  def campaign_for(identity_type, identity_id)
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                     campaign_type: 'blast', channel: 'email', audience_mode: 'static',
                     from_identity_type: identity_type, from_identity_id: identity_id,
                     throttle_per_day: 500)
  end

  def verified_domain(hostname)
    company.company_domains.create!(
      hostname: hostname, email_enabled: true, email_verified_at: Time.current,
      ses_dkim_tokens: %w[a b c], ses_mail_from_domain: "mail.#{hostname}"
    )
  end

  def mailbox_for(user, provider: 'oauth_outlook', address: nil)
    UserEmailConnection.create!(
      company_id: company.id, user_id: user.id, provider: provider,
      email_address: address || user.email, is_active: true
    )
  end

  describe 'when the sender address is on a verified domain' do
    let!(:domain) { verified_domain('dealer.example') }
    let(:campaign) { campaign_for('User', user.id) }

    it 'routes through the tenant SES identity instead of the mailbox' do
      mailbox_for(user)

      resolved = campaign.resolve_email_connection_for_step

      expect(resolved).to be_a(Ses::SendingIdentity)
      expect(resolved.provider).to eq('aws_ses')
      expect(resolved.company_domain).to eq(domain)
    end

    it 'keeps the reps own address as the visible sender' do
      mailbox_for(user)

      expect(campaign.resolve_email_connection_for_step.email_address).to eq('rep@dealer.example')
    end

    it 'lets a rep with no connected mailbox send at all' do
      expect(UserEmailConnection.where(user_id: user.id)).to be_empty

      expect(campaign.resolve_email_connection_for_step).to be_a(Ses::SendingIdentity)
    end

    it 'passes the start preflight on the domain alone, with no mailbox' do
      campaign.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi',
                                      body_blocks: [{ 'type' => 'text', 'html' => 'a' }],
                                      wait_days: 0, wait_hours: 0)
      campaign.create_campaign_audience!(source_type: 'Lead', filter_tree: {})

      expect(campaign.reload.can_start?).to be true
    end

    it 'counts rate limits against the domain, not the mailbox' do
      mailbox_for(user)

      expect(campaign.sending_connection_key).to eq("CompanyDomain:#{domain.id}")
    end

    it 'gives the domain SES rate limits rather than the conservative fallback' do
      limits = Messaging::SendRateLimits.for(connection_key: "CompanyDomain:#{domain.id}")

      expect(limits).to eq(Messaging::SendRateLimits::PROVIDER_DEFAULTS['aws_ses'])
      expect(limits).not_to eq(Messaging::SendRateLimits::FALLBACK)
    end

    it 'covers a subdomain address, since an SES identity signs for subdomains' do
      mailbox_for(user, address: 'rep@mail.dealer.example')

      expect(campaign.resolve_email_connection_for_step).to be_a(Ses::SendingIdentity)
    end

    # CommunicationService stamps user_id into metadata['sender_user_id'], which is what
    # InboundEmail::ReplyNotifier reads to route a reply back to the person who sent it.
    # Losing it on the SES path would silently divert every campaign reply to the entity
    # owner, or to "any active company user" when there is no owner.
    it 'attributes the send to the rep so replies come back to them' do
      mailbox_for(user)

      expect(campaign.resolve_email_connection_for_step.user_id).to eq(user.id)
    end

    it 'attributes the send even when the rep has no connected mailbox' do
      expect(campaign.resolve_email_connection_for_step.user_id).to eq(user.id)
    end

    # A real user here would make BaseProvider#load_config prefer that user's own mailbox
    # connection, handing AwsSesProvider an OAuth config with no AWS keys or region.
    it 'exposes no user object, so the provider keeps the SES config' do
      mailbox_for(user)

      expect(campaign.resolve_email_connection_for_step.user).to be_nil
    end
  end

  describe 'when no verified domain covers the address' do
    let(:campaign) { campaign_for('User', user.id) }

    it 'falls through to the existing mailbox unchanged' do
      mailbox = mailbox_for(user)

      resolved = campaign.resolve_email_connection_for_step

      expect(resolved).to eq(mailbox)
      expect(campaign.sending_connection_key).to eq("UserEmailConnection:#{mailbox.id}")
    end

    it 'ignores a domain that is enabled but not yet verified' do
      company.company_domains.create!(hostname: 'dealer.example', email_enabled: true, email_verified_at: nil)
      mailbox = mailbox_for(user)

      expect(campaign.resolve_email_connection_for_step).to eq(mailbox)
    end

    it 'ignores a verified domain belonging to another company' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(3)}")
      other.company_domains.create!(hostname: 'dealer.example', email_enabled: true,
                                    email_verified_at: Time.current)
      mailbox = mailbox_for(user)

      expect(campaign.resolve_email_connection_for_step).to eq(mailbox)
    end

    it 'ignores a domain that merely shares a suffix with the address' do
      verified_domain('otherdealer.example')
      mailbox = mailbox_for(user)

      expect(campaign.resolve_email_connection_for_step).to eq(mailbox)
    end

    it 'still returns nil when there is neither a domain nor a mailbox' do
      user.update!(email: 'rep@unverified.example')

      expect(campaign.resolve_email_connection_for_step).to be_nil
    end
  end

  describe 'Owner mode' do
    let!(:domain) { verified_domain('dealer.example') }
    let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
    let(:campaign) { campaign_for('Owner', nil) }

    it 'resolves the recipients owner onto the verified domain' do
      lead = Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B',
                          email: 'buyer@example.com', owner_id: user.id)

      resolved = campaign.resolve_email_connection_for_step(recipient: lead)

      expect(resolved).to be_a(Ses::SendingIdentity)
      expect(resolved.email_address).to eq('rep@dealer.example')
    end

    it 'returns nil when the recipient has no owner' do
      lead = Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B',
                          email: 'buyer@example.com')

      expect(campaign.resolve_email_connection_for_step(recipient: lead)).to be_nil
    end

    # One shared campaign, a different sender per recipient. Attribution has to follow the
    # recipient's own owner or replies land on whoever the campaign was created by.
    it 'attributes each send to that recipients owner' do
      other = User.create!(email: 'rep2@dealer.example', first_name: 'S', last_name: 'T',
                           password: 'Pass1234!', company_id: company.id)
      mine = Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B',
                          email: 'buyer@example.com', owner_id: user.id)
      theirs = Lead.create!(company: company, source: source, first_name: 'C', last_name: 'D',
                            email: 'buyer2@example.com', owner_id: other.id)

      expect(campaign.resolve_email_connection_for_step(recipient: mine).user_id).to eq(user.id)
      expect(campaign.resolve_email_connection_for_step(recipient: theirs).user_id).to eq(other.id)
    end
  end
end
