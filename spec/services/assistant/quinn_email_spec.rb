# frozen_string_literal: true

require 'rails_helper'

# Quinn AI answers a buyer's email reply, or drafts the answer for a rep, or
# hands it over, by the dealer's choice; the dealer's handoff switches; and
# every model call is logged with its tokens (E96, 2026-11-07).
RSpec.describe 'Quinn AI email replies', type: :request do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)} Homes", industry: 'manufactured_housing') }
  let!(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Jordan', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:lead) { company.leads.create!(first_name: 'Tia', last_name: 'May', phone: '3035550144', email: 'tia@example.com', owner_id: rep.id, sms_inquiry_consent: true) }
  let!(:conversation) do
    company.conversations.create!(conversable: lead, sender_number: '+17205550100', buyer_phone: '+13035550144',
                                  status: 'active', assistant_enabled: true, started_at: 2.days.ago)
  end
  let(:emails) { [] }

  def buyer_emails(body)
    Communication.create!(company_id: company.id, communicable: lead, channel: 'email', direction: 'inbound', status: 'delivered',
                          from_address: 'tia@example.com', to_address: 'reply+lead@x.test', subject: 'Re: Homes that fit',
                          body: body, metadata: { reply_tracking_token: "lead-#{lead.id}" })
  end

  def brain_says(reply, handoff: false, reason: nil)
    allow_any_instance_of(Assistant::Brain).to receive(:post).and_return(
      'model' => 'claude-sonnet-4-6', 'usage' => { 'input_tokens' => 2000, 'output_tokens' => 100 },
      'content' => [{ 'type' => 'tool_use', 'input' => { 'reply' => reply, 'handoff' => handoff, 'handoff_reason' => reason, 'summary' => 'Wants a 3 bed.' } }]
    )
  end

  before do
    TenantModuleOverride.create!(company: company, module_key: 'marketing.lead_assistant', is_enabled: true)
    Assistant::Settings.for(company).update!('enabled' => true)
    mails = emails
    allow(CommunicationService).to receive(:send_email) { |**args| mails << args; { success: true } }
  end

  it 'answers an email reply by email, reading only the new part of their email, and logs the tokens' do
    brain_says('Yes, the Hawthorne has a covered porch. Would Saturday work to see it?')
    buyer_emails('<p>Does it have a porch?</p><p>On Tue, Nov 4, 2026 Quinn wrote:</p><blockquote>Two homes fit</blockquote>')
    expect(conversation.reload.status).to eq('active')

    perform_enqueued_jobs(only: AssistantReplyJob)
    expect(emails.last).to include(to: 'tia@example.com', subject: 'Re: Homes that fit', category: 'transactional')
    expect(emails.last[:body]).to include('covered porch')
    expect(emails.last[:metadata]).to include('sent_by' => 'assistant')

    log = AiQueryLog.where(company_id: company.id).last
    expect(log).to have_attributes(feature: 'quinn_email_reply', module_key: 'marketing.lead_assistant', input_tokens: 2000,
                                   output_tokens: 100, cost_cents: 1)

    history = Assistant::Brain.new(conversation: conversation, settings: Assistant::Settings.for(company), history: conversation.history(10))
                              .send(:messages)
    expect(history.last[:content]).to eq('Does it have a porch?')
  end

  it 'drafts the answer for a rep to approve when the dealer asks, and sends it from the Inbox' do
    Assistant::Settings.for(company).update!('email_replies' => 'draft')
    brain_says('Yes, it has a porch.')
    buyer_emails('Does it have a porch?')
    perform_enqueued_jobs(only: AssistantReplyJob)
    expect(emails).to be_empty
    expect(conversation.reload.draft_reply).to include('body' => 'Yes, it has a porch.', 'subject' => 'Re: Homes that fit')
    expect(Notification.where(notification_type: 'assistant_draft', recipient: rep)).to exist

    get '/api/crm/conversations', headers: headers, params: { view: 'needs_you' }
    expect(JSON.parse(response.body)['items'].map { |r| r['id'] }).to include(conversation.id)

    post "/api/crm/conversations/#{conversation.id}/send_draft", headers: headers, params: { body: 'Yes, it has a big covered porch.' }.to_json
    expect(emails.last[:body]).to include('big covered porch')
    expect(emails.last[:metadata]).to include('approved_by_user_id' => rep.id)
    expect(conversation.reload).to have_attributes(draft_reply: nil, status: 'active')
  end

  it 'hands an email to a person when the dealer chose that' do
    Assistant::Settings.for(company).update!('email_replies' => 'rep')
    buyer_emails('Does it have a porch?')
    expect(conversation.reload).to have_attributes(status: 'handed_off', handoff_reason: 'email_reply')
  end

  it 'follows the dealer\'s handoff switches' do
    settings = Assistant::Settings.for(company)
    prompt = -> { Assistant::Brain.new(conversation: conversation.reload, settings: Assistant::Settings.for(company), history: []).system_prompt }
    expect(prompt.call).to include('ready_to_buy').and include('say you will check with the team, and hand off')

    settings.update!('handoff_on_ready' => false, 'handoff_on_unknown' => false)
    expect(prompt.call).not_to include('ready_to_buy')
    expect(prompt.call).to include('Do not hand off for this')

    settings.update!('handoff_after' => 5)
    5.times { |i| buyer_emails("Question #{i}") }
    brain_says('Sure.')
    perform_enqueued_jobs(only: AssistantReplyJob)
    expect(conversation.reload).to have_attributes(status: 'handed_off', handoff_reason: 'long_conversation')
  end

  it 'does not count Quinn\'s own email as a person answering' do
    Communication.create!(company_id: company.id, communicable: lead, channel: 'email', direction: 'outbound', status: 'sent',
                          from_address: 'rep@x.test', to_address: 'tia@example.com', subject: 'Hi', body: '<p>Hi</p>',
                          user_id: rep.id, conversation_id: conversation.id, metadata: { sent_by: 'assistant' })
    expect(conversation.reload.last_person_reply_at).to be_nil
  end

  it 'shows platform admins what Quinn cost each dealer this month' do
    AiQueryLog.create!(company_id: company.id, feature: 'quinn_text_reply', module_key: 'marketing.lead_assistant',
                       input_tokens: 3000, output_tokens: 200, cost_cents: 1, execution_status: 'success')
    SmsUsageLog.log!(company: company, direction: 'outbound', source: 'assistant')
    staff = User.create!(email: "ops-#{SecureRandom.hex(4)}@example.com", first_name: 'Op', last_name: 'Staff', password: 'Pass1234!',
                         company_id: Company.create!(name: "DT #{SecureRandom.hex(3)}").id, role: 'platform_admin', status: 'active')
    get '/api/admin/assistant_usage', headers: { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: staff.id, company_id: staff.company_id)}" }
    row = JSON.parse(response.body)['items'].detect { |r| r['company_id'] == company.id }
    expect(row).to include('ai_calls' => 1, 'input_tokens' => 3000, 'texts_sent' => 1, 'ai_cost_cents' => 1)
  end

  it 'lists the lead under Waiting on you in the Inbox in the Workqueue while a draft waits' do
    conversation.update_columns(assigned_user_id: rep.id, draft_reply: { 'channel' => 'email', 'subject' => 'Re: Hi', 'body' => 'Yes' })
    ids = WorkqueueService.new(company: company, user: rep, queue_id: 'leads_inbox_waiting').items[:items].map { |r| r[:entity_id] }
    expect(ids).to include(lead.id)
  end
end
