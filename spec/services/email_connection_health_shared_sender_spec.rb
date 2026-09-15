# frozen_string_literal: true

require 'rails_helper'

# A location, company or platform sender lives on a communications Setting row,
# so before this nobody heard when it broke. Factory Direct's Auburn mailbox sat
# on a revoked Microsoft grant for over a day while its lead emails failed, and
# its notification emails had been refused by SES for a week. Both only ever
# reached the log.
RSpec.describe EmailConnectionHealth, 'shared senders' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:location) do
    Location.create!(company_id: company.id, name: 'Auburn', code: "AUB-#{SecureRandom.hex(2)}", active: true)
  end
  let(:lead) { Struct.new(:company, :location).new(company, location) }

  def make_user(role: 'staff', email: nil)
    User.create!(email: email || "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: role, status: 'active')
  end

  let!(:owner)         { make_user(email: "owner-#{SecureRandom.hex(3)}@example.com") }
  let!(:company_admin) { make_user(role: 'company_admin') }
  let!(:location_admin) do
    make_user.tap do |u|
      UserLocation.create!(user: u, location: location, company: company, location_role: 'location_admin')
    end
  end
  let!(:bystander) { make_user }

  let(:revoked) do
    { 'error' => 'invalid_grant',
      'error_description' => 'AADSTS50173: The provided grant has expired due to it being revoked.' }
  end

  def broken_for(user)
    Notification.where(recipient: user, notification_type: 'email_connection_broken')
  end

  def all_broken
    Notification.where(notification_type: 'email_connection_broken')
  end

  def set_location_mailbox
    Setting.set('Location', location.id, 'communications', {
      'email' => {
        'provider' => 'oauth_microsoft', 'oauthProvider' => 'microsoft',
        'oauthEmail' => owner.email, 'fromEmail' => owner.email,
        'oauthAccessToken' => 'stale', 'oauthRefreshToken' => 'rtok',
        'oauthExpiresAt' => 1.hour.ago.iso8601
      }
    })
  end

  def health(scope_type, scope_id)
    Setting.get(scope_type, scope_id, 'communications').dig('email', EmailConnectionHealth::HEALTH_KEY)
  end

  def stub_token_endpoint(body)
    allow(Net::HTTP).to receive(:start).and_return(double(body: body.to_json))
  end

  def load_location_config
    CommunicationSettingsService.for_company(company, location: location).email_config
  end

  describe 'a revoked grant on a location mailbox' do
    before { set_location_mailbox }

    it 'notifies the owner and the admins who can reconnect it, once each' do
      stub_token_endpoint(revoked)

      expect { load_location_config }
        .to change { broken_for(owner).count }.by(1)
        .and change { broken_for(company_admin).count }.by(1)
        .and change { broken_for(location_admin).count }.by(1)
      expect(broken_for(bystander).count).to eq(0)
      expect(health('Location', location.id).dig('mailbox', 'error')).to include('invalid_grant')

      expect { load_location_config }.not_to change { all_broken.count }
    end

    it 'tells the owner the mailbox and where to reconnect it' do
      stub_token_endpoint(revoked)
      load_location_config

      note = broken_for(owner).last
      expect(note.message).to include("The Auburn location's shared Outlook/Microsoft 365 mailbox (#{owner.email})")
      expect(note.message).not_to match(/[\u{2013}\u{2014}]/)
      expect(note.action_url).to eq("/locations/#{location.id}")
    end

    it 'ignores a transient provider error' do
      stub_token_endpoint('error' => 'temporarily_unavailable', 'error_description' => 'Try again')

      expect { load_location_config }.not_to change { all_broken.count }
      expect(health('Location', location.id)).to be_nil
    end

    it 'tells a sender who arrives after the first notice, and only them' do
      stub_token_endpoint(revoked)
      load_location_config
      rep = make_user

      expect {
        described_class.flag_send_failure!(
          error: 'Microsoft Graph API error (401): Lifetime validation failed, the token is expired.',
          user: rep, communicable: lead
        )
      }.to change { all_broken.count }.by(1)
      expect(broken_for(rep).count).to eq(1)
    end

    it 'tells the teammate an internal email was meant for' do
      stub_token_endpoint(revoked)
      load_location_config
      teammate = make_user

      expect {
        described_class.flag_send_failure!(error: 'invalid_grant', communicable: lead,
                                           to_address: "Josh <#{teammate.email.upcase}>")
      }.to change { broken_for(teammate).count }.by(1)
    end

    it 'clears once a refresh succeeds, so the next outage is reported again' do
      stub_token_endpoint(revoked)
      load_location_config
      expect(health('Location', location.id)).to be_present

      stub_token_endpoint('access_token' => 'fresh', 'expires_in' => 3600)
      expect(load_location_config[:smtp_password]).to eq('fresh')
      expect(health('Location', location.id)).to be_nil
    end

    it 'clears when the mailbox is reconnected' do
      stub_token_endpoint(revoked)
      load_location_config

      Api::V1::OauthEmailController.new.send(
        :merge_communications_setting, 'location', location.id,
        { 'provider' => 'oauth_microsoft', 'oauthAccessToken' => 'new' }, owner.id
      )
      expect(health('Location', location.id)).to be_nil
    end
  end

  describe '.flag_send_failure!' do
    before { set_location_mailbox }

    it "blames the rep's own mailbox when they have one, not the shared sender" do
      rep = make_user
      connection = UserEmailConnection.create!(
        user_id: rep.id, provider: 'oauth_gmail', email_address: "r-#{SecureRandom.hex(3)}@gmail.com",
        is_active: true, verified_at: Time.current, oauth_expires_at: 1.hour.from_now,
        oauth_token_encrypted: 'tok', oauth_refresh_token_encrypted: 'rtok'
      )

      expect(described_class.flag_send_failure!(error: 'invalid_grant', user: rep, communicable: lead)).to be true
      expect(connection.reload.needs_reauth?).to be true
      expect(health('Location', location.id)).to be_nil
    end

    it 'ignores an ordinary failure such as a bad recipient' do
      expect(described_class.flag_send_failure!(error: 'Recipient address rejected', communicable: lead)).to be false
      expect(health('Location', location.id)).to be_nil
    end

    it 'is cleared by a later successful send through the same sender' do
      described_class.flag_send_failure!(error: 'invalid_grant', communicable: lead)
      expect(health('Location', location.id)).to be_present

      described_class.clear_send_failure!(communicable: lead)
      expect(health('Location', location.id)).to be_nil
    end
  end

  describe 'notification emails refused by SES' do
    let(:ses_error) do
      'Email address is not verified. The following identities failed the check in region US-WEST-2: "kyle@example.com"'
    end
    let(:recipient) { make_user }
    let(:notification) do
      NotificationService.create(recipient: recipient, notification_type: :system_alert, message: 'hi',
                                 company_id: company.id)
    end

    before do
      Setting.set('Company', company.id, 'communications',
                  { 'email' => { 'provider' => 'smtp', 'fromEmail' => owner.email } })
    end

    it 'flags the company From address and tells the admins and the person who missed the email' do
      expect {
        described_class.flag_system_mail_failure!(notification: notification, recipient: recipient,
                                                  error: StandardError.new(ses_error))
      }.to change { broken_for(company_admin).count }.by(1)
        .and change { broken_for(owner).count }.by(1)
        .and change { broken_for(recipient).count }.by(1)

      expect(broken_for(location_admin).count).to eq(0)
      expect(health('Company', company.id).dig('system_mail', 'error')).to include('not verified')
      expect(broken_for(recipient).last.message).to start_with('Notification emails are failing.')
    end

    it 'is reported by NotificationService.send_email instead of only logged' do
      mail = double('mail')
      allow(mail).to receive(:deliver_now).and_raise(StandardError, ses_error)
      allow(NotificationMailer).to receive(:broadcast_notification).and_return(mail)

      expect(NotificationService.send_email(notification, recipient)).to be false
      expect(broken_for(company_admin).count).to eq(1)
    end

    it 'is not cleared by the other channel recovering' do
      described_class.flag_system_mail_failure!(notification: notification, recipient: recipient, error: ses_error)

      described_class.clear_shared!(scope_type: 'Company', scope_id: company.id, channel: 'mailbox')
      expect(health('Company', company.id)['system_mail']).to be_present

      described_class.clear_system_mail_failure!(notification: notification)
      expect(health('Company', company.id)).to be_nil
    end
  end
end
