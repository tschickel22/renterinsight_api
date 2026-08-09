# frozen_string_literal: true

require 'rails_helper'

# Campaigns already refused suppressed addresses in CampaignSender. Nothing else did, so a
# rep pressing Email on a lead, a nurture step, or a quote all kept mailing an address the
# platform already knew was dead. Every one of those retries is counted by SES against a
# sending account shared by every tenant.
RSpec.describe CommunicationService, 'suppressed recipients' do
  let(:lead) { create(:lead, email: 'dead@example.com') }
  let(:company) { lead.company }

  def suppress!(reason, email: 'dead@example.com')
    CampaignSuppression.create!(
      company_id: company.id, email_address: email, reason: reason
    )
  end

  def send_to(address, **opts)
    described_class.send_communication(
      communicable: lead, channel: 'email', to: address,
      subject: 'Test', body: 'Body', **opts
    )
  end

  before do
    allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(true)
    allow_any_instance_of(Providers::Email::SmtpProvider).to receive(:send_message)
      .and_return({ success: true, external_id: 'msg_1' })
  end

  it 'refuses an address that previously hard bounced' do
    suppress!('bounce_hard')

    expect { send_to('dead@example.com') }
      .to raise_error(CommunicationService::SuppressedRecipientError, /hard bounced/)
  end

  it 'refuses an address that reported us as spam' do
    suppress!('complaint')

    expect { send_to('dead@example.com') }
      .to raise_error(CommunicationService::SuppressedRecipientError)
  end

  it 'creates no communication record for a refused send' do
    suppress!('bounce_hard')

    expect { send_to('dead@example.com') rescue nil }
      .not_to change(Communication, :count)
  end

  it 'matches the suppression regardless of the case the address is passed in' do
    suppress!('bounce_hard')

    expect { send_to('Dead@Example.COM') }
      .to raise_error(CommunicationService::SuppressedRecipientError)
  end

  # An unsubscribe is a marketing preference, not a dead mailbox. Somebody who opted out of
  # campaigns must still receive the quote they asked a salesperson for.
  it 'still sends to an address suppressed only as an unsubscribe' do
    suppress!('unsubscribe')

    expect { send_to('dead@example.com') }.not_to raise_error
  end

  it 'sends normally to an address that is not suppressed' do
    expect { send_to('fine@example.com') }.not_to raise_error
  end

  it 'scopes the check to the company, so another tenant\'s bounce does not block ours' do
    other = Company.create!(name: "OC-#{SecureRandom.hex(4)}")
    CampaignSuppression.create!(
      company_id: other.id, email_address: 'dead@example.com', reason: 'bounce_hard'
    )

    expect { send_to('dead@example.com') }.not_to raise_error
  end

  it 'can be overridden explicitly for a caller that must send anyway' do
    suppress!('bounce_hard')

    expect { send_to('dead@example.com', skip_suppression_check: true) }.not_to raise_error
  end
end
