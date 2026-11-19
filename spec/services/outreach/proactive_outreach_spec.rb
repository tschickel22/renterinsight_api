# frozen_string_literal: true

require 'rails_helper'

# Proactive Outreach phase 2 (E105): who may be contacted, what may be said, and
# that nothing reaches a lead without approval, consent and an active gate.
RSpec.describe 'Proactive Outreach pilot' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:tom) do
    User.create!(email: "t-#{SecureRandom.hex(4)}@example.com", first_name: 'Tom', last_name: 'Schickel', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:settings) { Outreach::Settings.for(company) }
  let(:wave) { company.outreach_waves.create!(name: 'Test', status: 'running', started_at: 1.minute.ago) }
  let(:item) { company.outreach_content_items.create!(title: 'Installs', url: 'https://vimeo.com/5', status: 'approved') }

  def lead!(attrs = {})
    company.leads.create!({ first_name: 'Pat', last_name: 'Lee', phone: "303555#{rand(1000..9999)}", email: "p#{SecureRandom.hex(3)}@example.com",
                            owner_id: tom.id, status: 'new', sms_inquiry_consent: true, state: 'CO' }.merge(attrs))
  end

  def target!(lead = lead!, attrs = {})
    wave.outreach_targets.create!({ company_id: company.id, lead_id: lead.id, channel: 'text', status: 'approved', draft_body: 'Hi Pat.' }.merge(attrs))
  end

  before do
    TenantModuleOverride.create!(company: company, module_key: 'marketing.proactive_outreach', is_enabled: true)
    settings.update!('enabled' => true, 'persona_name' => 'Tom Schickel', 'sender_user_id' => tom.id, 'postal_address' => '1 Main St, Denver, CO')
    allow(Outreach::Clock).to receive(:send_now?).and_return(true)
    allow(Outreach::Clock).to receive(:reply_now?).and_return(true)
  end

  describe Outreach::Eligibility do
    subject(:eligibility) { described_class.new(company) }

    it 'keeps only new leads nobody is working' do
      ok = lead!
      converted = lead!(is_converted: true)
      working = lead!(status: 'contacted')
      nurtured = lead!
      NurtureEnrollment.create!(enrollable: nurtured, company_id: company.id, nurture_sequence_id: NurtureSequence.create!(name: 'N', company_id: company.id).id, status: 'running')
      already = lead!
      wave.outreach_targets.create!(company_id: company.id, lead_id: already.id)

      ids = eligibility.scope.pluck(:id)
      expect(ids).to include(ok.id)
      expect(ids).not_to include(converted.id, working.id, nurtured.id, already.id)
    end

    it 'never texts without consent or after an opt out' do
      no_consent = lead!(sms_inquiry_consent: false)
      expect(eligibility.reach(no_consent)).to have_attributes(text: false, email: true)

      stopped = lead!
      CommunicationPreference.find_or_create_for(recipient: stopped, channel: 'sms').opt_out!('STOP')
      expect(eligibility.reach(stopped).text).to be(false)
    end
  end

  describe Outreach::AudienceBuilder do
    before do
      CustomField.create!(company: company, module: 'leads', name: 'Category', field_key: 'category', field_type: 'text')
    end

    it 'drops AI rules no lead could pass, so one invented tag does not empty the audience' do
      retailer = lead!(custom_field_values: { 'category' => 'Retailer' })
      lead!(custom_field_values: { 'category' => 'Supplier' })
      tree = { 'type' => 'and', 'children' => [
        { 'field' => 'custom:category', 'operator' => 'equals', 'value' => 'Retailer' },
        { 'field' => 'source_name', 'operator' => 'equals', 'value' => 'Trade Show' },
        { 'type' => 'or', 'children' => [{ 'field' => 'tags', 'operator' => 'tags_include', 'value' => 'email_opened' }] }
      ] }
      generation = instance_double(AudienceAiGeneration, generated_filter_tree: tree)
      allow_any_instance_of(Audiences::AiBuilder).to receive(:generate).and_return(generation)
      allow(Outreach::AiClient).to receive(:call).and_return('picks' => [])

      building = company.outreach_waves.create!(name: 'Build', status: 'building', prompt: 'Retailers from trade shows who opened emails', target_size: 1)
      described_class.new(building, user: tom).call

      expect(building.reload.filter_tree['children']).to eq([tree['children'].first])
      expect(building.outreach_targets.pluck(:lead_id)).to eq([retailer.id])
      expect(building.outreach_targets.first.channel).to eq('email')
      expect(building.status).to eq('audience_ready')
    end

    it 'on DealerTide keeps only retailers, whether labeled MH Retailer or Retailer' do
      company.update!(name: 'DealerTide Test')
      mh = lead!(custom_field_values: { 'category' => 'MH Retailer' })
      plain = lead!(custom_field_values: { 'category' => 'Retailer' })
      lead!(custom_field_values: { 'category' => 'Supplier' })
      allow_any_instance_of(Audiences::AiBuilder).to receive(:generate)
        .and_return(instance_double(AudienceAiGeneration, generated_filter_tree: { 'type' => 'and', 'children' => [] }))
      allow(Outreach::AiClient).to receive(:call).and_return('picks' => [])

      building = company.outreach_waves.create!(name: 'Build', status: 'building', prompt: 'Retailers', target_size: 5)
      described_class.new(building, user: tom).call
      expect(building.outreach_targets.pluck(:lead_id)).to contain_exactly(mh.id, plain.id)
    end

    it 'says when leads match but none can be contacted' do
      lead!(custom_field_values: { 'category' => 'Retailer' }, status: 'contacted')
      tree = { 'type' => 'and', 'children' => [{ 'field' => 'custom:category', 'operator' => 'equals', 'value' => 'Retailer' }] }
      allow_any_instance_of(Audiences::AiBuilder).to receive(:generate).and_return(instance_double(AudienceAiGeneration, generated_filter_tree: tree))

      building = company.outreach_waves.create!(name: 'Build', status: 'building', prompt: 'Retailers')
      expect { described_class.new(building, user: tom).call }.to raise_error(Outreach::AiClient::Error, /1 lead match that description, but none can be contacted/)
    end
  end

  describe 'sender' do
    it 'can be someone outside the company whose mailbox is connected for it, never anyone else' do
      outside = Company.create!(name: "Platform-#{SecureRandom.hex(3)}")
      admin = User.create!(email: "pa-#{SecureRandom.hex(3)}@example.com", first_name: 'Tom', last_name: 'Admin', password: 'Pass1234!',
                           company_id: outside.id, role: 'platform_admin', status: 'active')
      stranger = User.create!(email: "s-#{SecureRandom.hex(3)}@example.com", first_name: 'Sam', last_name: 'Else', password: 'Pass1234!',
                              company_id: outside.id, role: 'company_admin', status: 'active')
      UserEmailConnection.create!(user_id: admin.id, company_id: company.id, provider: 'oauth_gmail', email_address: admin.email, is_active: true)

      settings.update!('sender_user_id' => admin.id)
      expect(settings.sender).to eq(admin)
      expect(settings.readiness[:mailbox]).to be(true)
      expect(settings.sender_choices.map { |c| c[:id] }).to include(admin.id, tom.id)

      settings.update!('sender_user_id' => stranger.id)
      expect(settings.sender).to be_nil
    end
  end

  describe Outreach::Guard do
    let(:lead) { lead! }

    it 'refuses links, prices, human claims and made up meetings' do
      expect(described_class.violation('See dealertide.com', channel: 'text', lead: lead)).to be_present
      expect(described_class.violation('It is $99 a month', channel: 'text', lead: lead)).to be_present
      expect(described_class.violation("I'm a real person, promise", channel: 'text', lead: lead)).to be_present
      expect(described_class.violation('Great meeting you at Biloxi', channel: 'text', lead: lead)).to be_present
      expect(described_class.violation('Would a short demo help?', channel: 'text', lead: lead)).to be_nil
    end

    it 'allows mentioning a meeting only for someone who visited the booth' do
      visited = lead!(custom_field_values: { 'visited_booth' => true })
      expect(described_class.violation('Great meeting you at Biloxi', channel: 'text', lead: visited)).to be_nil
    end

    it 'spots the question without tripping on product questions' do
      expect(described_class.asks_if_ai?('Is this a bot?')).to be(true)
      expect(described_class.asks_if_ai?('are you a real person')).to be(true)
      expect(described_class.asks_if_ai?('Is the inventory feed automated?')).to be(false)
    end
  end

  describe 'sending' do
    let(:communication) { Communication.create!(company_id: company.id, communicable: lead_for_send, direction: 'outbound', channel: 'sms', status: 'sent', body: 'x', from_address: '+17205550100', to_address: '+13035550100') }
    let(:lead_for_send) { lead! }

    it 'sends an approved text with the tracked video and opt out wording' do
      target = target!(lead_for_send, draft_content_item_id: item.id)
      sent = nil
      allow(Assistant::Messenger).to receive(:deliver!) { |_c, **args| sent = args[:body]; { success: true, communication: communication } }

      Outreach::WaveRunner.new(wave).run

      expect(sent).to include('Hi Pat.', '/o/v/', 'Reply STOP to opt out.')
      expect(target.reload).to have_attributes(status: 'sent', touch_count: 1)
      expect(target.next_touch_at).to be_within(1.minute).of(1.day.from_now)
      expect(target.conversation.assigned_user_id).to eq(tom.id)
    end

    it 'sends nothing that was not approved' do
      target!(lead_for_send, status: 'drafted')
      expect(Assistant::Messenger).not_to receive(:deliver!)
      Outreach::WaveRunner.new(wave).run
    end

    it 'sends nothing and pauses once the module is removed' do
      target!(lead_for_send)
      TenantModuleOverride.find_by(company: company, module_key: 'marketing.proactive_outreach').update!(is_enabled: false)
      expect(Assistant::Messenger).not_to receive(:deliver!)

      Outreach::WaveRunner.new(wave).run
      expect(wave.reload).to have_attributes(status: 'paused')
    end

    it 'skips a lead who joined a campaign after being chosen' do
      target = target!(lead_for_send)
      campaign = Campaign.create!(company_id: company.id, created_by_user_id: tom.id, name: 'C', campaign_type: 'blast', from_identity_type: 'User', from_identity_id: tom.id, throttle_per_day: 10)
      CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead', recipient_id: lead_for_send.id, status: 'active', sms_phone_snapshot: lead_for_send.phone)
      expect(Assistant::Messenger).not_to receive(:deliver!)

      Outreach::WaveRunner.new(wave).run
      expect(target.reload).to have_attributes(status: 'stopped', stop_reason: 'on a campaign, nurture or workflow')
    end

    it 'keeps to the daily limit' do
      wave.update!(daily_limit: 1)
      2.times { target!(lead!) }
      allow(Assistant::Messenger).to receive(:deliver!).and_return({ success: true, communication: communication })

      Outreach::WaveRunner.new(wave).run
      expect(wave.outreach_targets.where(status: 'sent').count).to eq(1)
    end

    it 'emails from the sender with an unsubscribe link and postal address' do
      target = target!(lead_for_send, channel: 'email', draft_subject: 'Hello')
      html = nil
      allow(CommunicationService).to receive(:send_email) do |**args|
        html = args[:body]
        expect(args[:user]).to eq(tom)
        { success: true, communication: communication }
      end

      Outreach::WaveRunner.new(wave).run
      expect(html).to include('Unsubscribe', '1 Main St, Denver, CO', '/o/u/', 'Tom Schickel')
      expect(target.reload.status).to eq('sent')
    end
  end

  describe 'replies' do
    let(:lead) { lead! }
    let(:conversation) { company.conversations.create!(conversable: lead, sender_number: '+17205550100', buyer_phone: lead.phone, assigned_user_id: tom.id, started_at: Time.current) }
    let!(:target) { target!(lead, status: 'sent', conversation_id: conversation.id, first_sent_at: 1.hour.ago) }

    def inbound(text)
      Communication.create!(company_id: company.id, communicable: lead, conversation_id: conversation.id, direction: 'inbound', channel: 'sms', status: 'delivered', body: text, from_address: lead.phone, to_address: '+17205550100')
    end

    before do
      allow(Outreach::Sender).to receive(:new).and_call_original
      allow(Assistant::Messenger).to receive(:deliver!) { |_c, **args| @reply = args[:body]; { success: true, communication: nil } }
      allow(Assistant::Handoff).to receive(:notify)
    end

    it 'tells the truth about being AI without asking the model, and hands to Tom' do
      inbound('Is this a bot?')
      expect(Outreach::AiClient).not_to receive(:call)

      Outreach::Responder.new(conversation).call
      expect(@reply).to include("I'm an AI assistant working with Tom Schickel")
      expect(conversation.reload).to have_attributes(status: 'handed_off', handed_off_to_user_id: tom.id)
    end

    it 'opts out both channels when someone asks to be left alone' do
      inbound('Not interested, take me off your list')
      Outreach::Responder.new(conversation).call

      expect(target.reload).to have_attributes(status: 'stopped', stop_reason: 'opted out')
      expect(CommunicationOptOut.check(channel: 'email', company: company, record: lead, address: lead.email).opted_out?).to be(true)
      expect(CommunicationOptOut.check(channel: 'sms', company: company, record: lead, address: lead.phone).opted_out?).to be(true)
    end

    it 'hands off rather than sending a reply that breaks the rules' do
      inbound('What does it cost?')
      allow(Outreach::AiClient).to receive(:call).and_return({ 'body' => 'Only $99 per month' })
      expect(Assistant::Messenger).not_to receive(:deliver!)

      Outreach::Responder.new(conversation).call
      expect(conversation.reload.status).to eq('handed_off')
    end

    it 'routes a reply to outreach and marks it replied' do
      message = inbound('Sounds interesting')
      expect(Assistant::Inbound.received(conversation, message)).to be(true)
      expect(target.reload).to have_attributes(status: 'replied')
      expect(target.recorded?('replied')).to be(true)
    end

    it 'leaves Quinn follow-ups out of an outreach conversation' do
      expect(Assistant::FollowUp.next_due(conversation)).to be_nil
    end
  end

  describe 'results and safety' do
    it 'counts a held back lead who books on their own, and the daily numbers' do
      contacted = target!(lead!, status: 'sent', first_sent_at: 1.hour.ago)
      held_back = lead!
      wave.outreach_targets.create!(company_id: company.id, lead_id: held_back.id, test_group: 'holdout')
      contacted.record!('sent', channel: 'text', communication_id: 1)
      contacted.record!('replied', channel: 'text', communication_id: 2)
      LeadActivity.create!(lead_id: held_back.id, user_id: tom.id, activity_type: 'meeting', status: 'pending', subject: 'Demo',
                           start_time: 2.days.from_now, end_time: 2.days.from_now + 30.minutes)

      Outreach::Sync.new(wave).run
      results = Outreach::Results.new(wave).to_h

      expect(results[:totals]).to include('sent' => 1, 'replied' => 1, 'booked' => 0)
      expect(results[:comparison]['holdout']).to include('people' => 1, 'booked' => 1)
      expect(results[:daily].first).to include('sent' => 1, 'replied' => 1)
    end

    it 'pauses on a spam complaint and after repeated unsubscribes' do
      target = target!(lead!, status: 'sent')
      target.record!('complained')
      expect(Outreach::Safety.new(wave).problem).to eq('a spam complaint came in')
    end

    it 'does not pause on one unsubscribe in a small wave' do
      target = target!(lead!, status: 'sent')
      target.record!('sent', channel: 'text', communication_id: 9)
      target.record!('unsubscribed')
      expect(Outreach::Safety.new(wave).problem).to be_nil
    end
  end
end
