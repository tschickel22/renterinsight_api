# frozen_string_literal: true

require 'rails_helper'

# A broken sender used to fail every enrollment one at a time, after which the
# scheduler found nobody left and completed the campaign (campaign 26 lost 586
# recipients in September 2026). It now pauses the campaign once, says why, and
# leaves everyone at their step.
RSpec.describe Campaigns::SenderHealth do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", first_name: 'R', last_name: 'P',
                 password: 'Pass1234!', company_id: company.id)
  end
  let!(:mailbox) do
    UserEmailConnection.create!(user_id: rep.id, company_id: company.id, provider: 'oauth_outlook',
                                email_address: rep.email, is_active: true)
  end

  def campaign(**attrs)
    Campaign.create!({ company_id: company.id, created_by_user_id: rep.id, name: 'Series',
                       campaign_type: 'drip', channel: 'email', from_identity_type: 'User',
                       from_identity_id: rep.id, throttle_per_day: 100, status: 'running' }.merge(attrs))
  end

  describe '.problem_for' do
    it 'is nil while the mailbox works' do
      expect(described_class.problem_for(campaign)).to be_nil
    end

    it 'asks for a reconnect when the mailbox has been flagged' do
      mailbox.update_columns(last_error_message: 'Reauth required: invalid_grant')

      expect(described_class.problem_for(campaign)).to have_attributes(
        code: 'sender_needs_reauth', reconnect_path: '/account/settings?tab=email'
      )
    end

    it 'names a missing mailbox' do
      mailbox.update!(is_active: false)

      expect(described_class.problem_for(campaign).code).to eq('sender_not_connected')
    end

    it 'names a sender who is not in the company' do
      outsider = User.create!(email: "o-#{SecureRandom.hex(3)}@example.com", first_name: 'O', last_name: 'U',
                              password: 'Pass1234!', company_id: Company.create!(name: 'Elsewhere').id)

      expect(described_class.problem_for(campaign(from_identity_id: outsider.id)).code).to eq('sender_missing')
    end

    it 'leaves Owner mode and waterfall campaigns to their per-recipient handling' do
      mailbox.update!(is_active: false)

      expect(described_class.problem_for(campaign(from_identity_type: 'Owner', from_identity_id: nil))).to be_nil
      expect(described_class.problem_for(campaign(email_waterfall: true))).to be_nil
    end
  end

  describe '.pause!' do
    let(:problem) { described_class::Problem.new(code: 'sender_needs_reauth', message: 'Reconnect it.', reconnect_path: '/x') }

    it 'pauses once with the reason and notifies the creator once' do
      c = campaign

      expect(described_class.pause!(c, problem)).to be true
      expect(described_class.pause!(c, problem)).to be false

      expect(c.reload).to have_attributes(status: 'paused')
      expect(c.pause_reason).to include('code' => 'sender_needs_reauth', 'paused_by' => 'system')
      expect(c.paused_at).to be_present
      expect(Notification.where(notification_type: 'campaign_paused_sender', recipient: rep).count).to eq(1)
    end

    it 'does not touch a campaign that is not running' do
      c = campaign(status: 'completed')

      expect(described_class.pause!(c, problem)).to be false
      expect(c.reload.status).to eq('completed')
    end
  end

  describe 'when a mailbox is flagged as needing reconnection' do
    it 'pauses the running campaigns sending through it, and only those' do
      affected = campaign
      other_rep = User.create!(email: "o-#{SecureRandom.hex(3)}@example.com", first_name: 'O', last_name: 'R',
                               password: 'Pass1234!', company_id: company.id)
      UserEmailConnection.create!(user_id: other_rep.id, company_id: company.id, provider: 'oauth_outlook',
                                  email_address: other_rep.email, is_active: true)
      unaffected = campaign(from_identity_id: other_rep.id)

      mailbox.mark_needs_reauth!('invalid_grant: token revoked')

      expect(affected.reload.status).to eq('paused')
      expect(affected.pause_reason['code']).to eq('sender_needs_reauth')
      expect(unaffected.reload.status).to eq('running')
    end
  end
end
