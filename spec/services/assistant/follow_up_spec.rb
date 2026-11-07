# frozen_string_literal: true

require 'rails_helper'

# Who texts a new lead when plays and nurtures also do, and Quinn AI's
# follow-ups until a visit is set (E96, Tom 2026-11-07).
RSpec.describe 'Quinn AI follow-ups and plays', type: :request do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)} Homes", industry: 'manufactured_housing') }
  let!(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Jordan', last_name: 'Rep', phone: '7205550111',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:own_number) { '+17205550100' }
  let(:sent) { [] }
  let(:emails) { [] }
  let(:lead) do
    company.leads.create!(first_name: 'Tia', last_name: 'May', phone: '(303) 555-0144', email: 'tia@example.com', owner_id: rep.id,
                          sms_inquiry_consent: true, origin: Lead::ORIGIN_INTAKE_FORM)
  end

  def brain_says(reply, subject: nil)
    allow_any_instance_of(Assistant::Brain).to receive(:call).and_return(
      Assistant::Brain::Result.new(reply: reply, qualification: {}, contact: {}, resend_invite: false, photo_home_id: nil,
                                   question: nil, question_answered: false, question_topic: nil, handoff: false,
                                   handoff_reason: nil, summary: '', usage: {}, subject: subject)
    )
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TWILIO_AUTH_TOKEN').and_return(nil)
    allow(ENV).to receive(:[]).with('TWILIO_PHONE_NUMBER').and_return(nil)
    calls = sent
    allow_any_instance_of(Providers::Sms::TwilioProvider).to receive(:send_message) do |_provider, **args|
      calls << args
      { success: true, external_id: "SM#{SecureRandom.hex(8)}", provider: 'twilio' }
    end
    mails = emails
    allow(CommunicationService).to receive(:send_email) { |**args| mails << args; { success: true } }
    TwilioAccount.create!(company: company, phone_number: own_number, phone_number_sid: "PN#{SecureRandom.hex(8)}", status: 'active')
    TenantModuleOverride.create!(company: company, module_key: 'marketing.lead_assistant', is_enabled: true)
    Assistant::Settings.for(company).update!('enabled' => true)
  end

  describe 'plays and nurtures that text' do
    it 'never puts a staff alert into the buyer\'s conversation' do
      starter = Assistant::Starter.for(lead)
      expect(starter.automation_route('+17205550111')).to eq(:normal)
    end

    it 'skips the play\'s text while Quinn AI leads, and sends it into Quinn\'s conversation when plays go first' do
      expect(Assistant::Starter.for(lead).automation_route(lead.phone)).to eq(:skip)

      Assistant::Settings.for(company).update!('texts_from' => 'plays')
      expect(Assistant::Starter.for(lead).automation_route(lead.phone)).to eq(:quinn)
    end

    it 'lets a nurture text an old lead into Quinn\'s conversation so Quinn answers the reply' do
      lead.update_columns(created_at: 3.days.ago, origin: nil)
      expect(Assistant::Starter.for(lead).automation_route(lead.phone)).to eq(:quinn)
    end

    it 'lists the plays and nurtures that text leads in the settings' do
      company.workflow_rules.create!(name: 'New lead welcome', entity_type: 'Lead', status: 'active', trigger: { event_type: 'lead.created' },
                                     steps: { nodes: [{ id: 'n1', type: 'send_sms', config: { to: '{{entity.phone}}', body: 'Hi' } }], edges: [] })
      company.workflow_rules.create!(name: 'Hot lead alert', entity_type: 'Lead', status: 'active', trigger: { event_type: 'lead.updated' },
                                     steps: { nodes: [{ id: 'n1', type: 'send_sms', config: { to: '{{entity.owner_phone}}', body: 'Hot' } }], edges: [] })
      get '/api/crm/lead_assistant_settings', headers: headers
      names = JSON.parse(response.body)['texting_automations'].map { |a| a['name'] }
      expect(names).to eq(['New lead welcome'])
    end
  end

  describe 'follow-ups' do
    let(:conversation) do
      Assistant::Starter.for(lead).send_first_text!(body: 'Hi Tia, this is Quinn.', sent_by: 'assistant')
      Conversation.find_by(conversable: lead, channel: 'sms')
    end

    before { allow(Assistant::Rules).to receive(:quiet_now?).and_return(false) }

    it 'schedules the first a day after Quinn opens, then alternates text and email' do
      expect(conversation.next_follow_up_at).to be_within(1.minute).of(conversation.started_at + 1.day)

      travel_to(conversation.started_at + 25.hours) do
        brain_says('Still thinking about a home for your land?')
        expect { Assistant::FollowUp.run_due }.to change { sent.size }.by(1)
        expect(conversation.reload.follow_up_count).to eq(1)
        expect(conversation.next_follow_up_at).to be_within(1.minute).of(conversation.started_at + 3.days)
      end

      travel_to(conversation.started_at + 3.days + 1.hour) do
        brain_says('Two homes fit what you described: the Hawthorne at $89,900.', subject: 'Homes that fit')
        Assistant::FollowUp.run_due
        expect(emails.last).to include(to: 'tia@example.com', subject: 'Homes that fit', category: 'nurture')
        expect(emails.last[:body]).to include('Hi Tia,').and include('Quinn')
      end
    end

    it 'starts over when the buyer writes, and stops when a rep takes over until it is handed back' do
      conversation.update_columns(follow_up_count: 2)
      inbound = Communication.create!(communicable: lead, company_id: company.id, channel: 'sms', direction: 'inbound', status: 'delivered',
                                      body: 'Maybe next month', to_address: own_number, from_address: '+13035550144', conversation_id: conversation.id)
      conversation.note_message!(inbound)
      expect(conversation.reload.follow_up_count).to eq(0)
      expect(conversation.next_follow_up_at).to be_within(1.minute).of(inbound.created_at + 1.day)

      Assistant::Handoff.taken_over!(conversation, rep)
      expect(conversation.reload.next_follow_up_at).to be_nil

      travel_to(10.days.from_now) do
        Assistant::Handoff.hand_back!(conversation)
        expect(conversation.reload.next_follow_up_at).to be_within(1.minute).of(1.day.from_now)
      end
    end

    it 'stops for a booked visit or a closed lead, and when the plan runs out' do
      conversation.update_columns(next_follow_up_at: 1.minute.ago, follow_up_anchor_at: 2.days.ago)
      lead.update_columns(status: 'won')
      Assistant::FollowUp.run_due
      expect(sent.size).to eq(1) # only Quinn's opener
      expect(conversation.reload.next_follow_up_at).to be_nil

      Assistant::Settings.for(company).update!('cadence' => 'light')
      conversation.update_columns(follow_up_count: 3)
      expect(Assistant::FollowUp.next_due(conversation.reload)).to be_nil
    end

    it 'texts only when told to, and emails a lead who never agreed to texts' do
      Assistant::Settings.for(company).update!('follow_up_channels' => 'text')
      conversation.update_columns(follow_up_count: 1, next_follow_up_at: 1.minute.ago, follow_up_anchor_at: 4.days.ago)
      brain_says('Checking in on your timeline.')
      Assistant::FollowUp.run_due
      expect(emails).to be_empty
      expect(sent.last[:body]).to include('Checking in')

      lead.update_columns(sms_inquiry_consent: false)
      conversation.update_columns(next_follow_up_at: 1.minute.ago, follow_up_anchor_at: 8.days.ago)
      brain_says('Here is a home that fits.', subject: 'A home that fits')
      Assistant::FollowUp.run_due
      expect(emails.size).to eq(1)
    end
  end

  it 'saves the texting choice, the plan and the channels' do
    put '/api/crm/lead_assistant_settings', headers: headers,
                                            params: { settings: { texts_from: 'plays', cadence: 'persistent', follow_up_channels: 'email' } }.to_json
    expect(JSON.parse(response.body)['settings']).to include('texts_from' => 'plays', 'cadence' => 'persistent', 'follow_up_channels' => 'email')
  end
end
