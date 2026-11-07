# frozen_string_literal: true

require 'rails_helper'

# Lead Assistant (backlog E96): a play's first text opens a conversation, the
# buyer's reply is answered by the assistant, and a person can take it over.
RSpec.describe 'Lead Assistant', type: :request do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)} Homes", industry: 'manufactured_housing') }
  let!(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Jordan', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let(:source) { Source.create!(name: 'Website', source_type: 'website', is_active: true) }
  let(:lead) do
    company.leads.create!(first_name: 'Tia', last_name: 'May', phone: '(303) 555-0144', email: 'tia@example.com',
                          owner_id: rep.id, source_id: source.id, sms_inquiry_consent: true)
  end
  let(:own_number) { '+17205550100' }
  let(:sent) { [] }

  def turn_on!(**attrs)
    TenantModuleOverride.create!(company: company, module_key: 'marketing.lead_assistant', is_enabled: true)
    Assistant::Settings.for(company).update!({ 'enabled' => true }.merge(attrs.stringify_keys))
  end

  def own_account!
    TwilioAccount.create!(company: company, phone_number: own_number, phone_number_sid: "PN#{SecureRandom.hex(8)}", status: 'active')
  end

  def brain_says(reply:, handoff: false, reason: nil, qualification: {}, contact: {}, resend_invite: false, photo_home_id: nil)
    allow_any_instance_of(Assistant::Brain).to receive(:call).and_return(
      Assistant::Brain::Result.new(reply: reply, qualification: qualification, contact: contact, resend_invite: resend_invite,
                                   photo_home_id: photo_home_id, handoff: handoff,
                                   handoff_reason: reason, summary: 'Wants a 3 bed on her land.', usage: {})
    )
  end

  def buyer_texts(body, to: own_number, from: '+13035550144')
    post '/webhooks/twilio/sms/inbound', params: { From: from, To: to, Body: body, MessageSid: "SM#{SecureRandom.hex(8)}" }
    expect(response).to have_http_status(:ok)
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
  end

  describe 'opening a conversation' do
    it 'sends the play text from the dealer number, naming the dealer, and opens a conversation' do
      own_account!
      turn_on!
      starter = Assistant::Starter.for(lead)
      expect(starter.takes_over?).to be(true)

      starter.send_first_text!(body: 'Hi Tia, thanks for asking about the Hawthorne!')

      conversation = Conversation.last
      expect(conversation).to have_attributes(company_id: company.id, conversable: lead, sender_number: own_number,
                                              buyer_phone: '+13035550144', pool: false, status: 'active')
      expect(sent.last[:body]).to start_with("#{company.name}: Hi Tia")
      expect(sent.last[:from]).to eq(own_number)
      expect(Communication.last.conversation_id).to eq(conversation.id)
    end

    it 'stays out of it when the dealer has not turned it on, the lead did not agree to texts, or a partner AI has the lead' do
      own_account!
      expect(Assistant::Starter.for(lead).takes_over?).to be(false)

      turn_on!
      lead.update!(sms_inquiry_consent: false)
      expect(Assistant::Starter.for(lead).takes_over?).to be(false)

      lead.update!(sms_inquiry_consent: true, source_id: Source.create!(name: 'Mobile Home Guys', source_type: 'partner', is_active: true).id)
      expect(Assistant::Starter.for(lead).takes_over?).to be(false)
    end

    it 'needs the add-on as well as the switch' do
      own_account!
      Assistant::Settings.for(company).update!('enabled' => true)
      expect(Assistant::Starter.for(lead).takes_over?).to be(false)
    end

    it 'uses a live pool number with the dealer and platform named on every text' do
      turn_on!
      Setting.set('Platform', 0, 'assistant_pool',
                  { 'live' => true, 'numbers' => [{ 'number' => '+19704632673', 'messaging_service_sid' => 'MGpool' }] })

      Assistant::Starter.for(lead).send_first_text!(body: 'Hi Tia, thanks for asking!')

      conversation = Conversation.last
      expect(conversation).to have_attributes(pool: true, sender_number: '+19704632673', messaging_service_sid: 'MGpool')
      expect(sent.last[:body]).to eq("#{company.name} via #{Brand.current.name}: Hi Tia, thanks for asking!")
      expect(sent.last[:pool_messaging_service_sid]).to eq('MGpool')
    end

    it 'does not use the pool until it is marked live' do
      turn_on!
      Setting.set('Platform', 0, 'assistant_pool', { 'live' => false, 'numbers' => [{ 'number' => '+19704632673' }] })
      expect(Assistant::Starter.for(lead).takes_over?).to be(false)
    end
  end

  describe 'answering the buyer' do
    let!(:conversation) do
      own_account!
      turn_on!
      Assistant::Starter.for(lead).send_first_text!(body: 'Hi Tia, thanks for asking!')
      Conversation.last
    end

    it 'answers a reply itself after a short wait, and the rep is not pinged' do
      brain_says(reply: 'Happy to help. Are you placing it on your own land?', qualification: { 'bedrooms' => '3 bedrooms' })

      expect { buyer_texts('Do you have 3 bed homes?') }.to have_enqueued_job(AssistantReplyJob)
      expect(Notification.where(notification_type: 'sms_reply_received')).to be_empty

      perform_enqueued_jobs
      expect(sent.last[:body]).to eq('Happy to help. Are you placing it on your own land?')
      expect(conversation.reload.qualification).to include('bedrooms' => '3 bedrooms')
      expect(lead.reload.preferred_bedrooms).to eq(3)
      expect(Communication.where(conversation_id: conversation.id).order(:id).last.metadata).to include('sent_by' => 'assistant', 'source' => 'assistant')
    end

    it 'puts the name, email and address the buyer types onto the lead, without overwriting what is there' do
      lead.update!(first_name: 'Text from (303) 555-0144', last_name: '', email: nil)
      brain_says(reply: 'Thanks Tia, I will send that over.',
                 contact: { 'first_name' => 'Tia', 'last_name' => 'May', 'email' => 'Tia.May@Example.com', 'zip' => '80601' })
      buyer_texts("I'm Tia May, tia.may@example.com, zip 80601")
      perform_enqueued_jobs
      expect(lead.reload).to have_attributes(first_name: 'Tia', last_name: 'May', email: 'tia.may@example.com', zip: '80601')

      brain_says(reply: 'Got it.', contact: { 'first_name' => 'Tee', 'email' => 'other@example.com' })
      buyer_texts('or other@example.com')
      perform_enqueued_jobs
      expect(lead.reload).to have_attributes(first_name: 'Tia', email: 'tia.may@example.com')
    end

    it "knows the buyer's booked visit, and sends the calendar invite again when asked" do
      allow(AppointmentInviteJob).to receive(:perform_later)
      allow(AppointmentBookingTextJob).to receive(:perform_later)
      start = 3.days.from_now.change(hour: 16)
      appt = LeadActivity.create!(lead: lead, user: rep, assigned_to: rep, activity_type: 'meeting', subject: 'Visit', status: 'pending',
                                  priority: 'medium', start_time: start, end_time: start + 1.hour, meeting_location: 'Sales office')
      prompt = Assistant::Brain.new(conversation: conversation, settings: Assistant::Settings.for(company), history: []).system_prompt
      expect(prompt).to include("#{Appointments::TimeText.for(appt, company)} at Sales office with Jordan")

      resent = []
      allow(AppointmentInviteJob).to receive(:perform_later) { |*args| resent << args }
      brain_says(reply: 'You are set for Tuesday at 4 PM at our Sales office. I sent the invite to your email again.', resend_invite: true)
      buyer_texts('What time is my appointment? Can you resend the invite?')
      perform_enqueued_jobs(except: [AppointmentInviteJob])
      expect(resent).to eq([['LeadActivity', appt.id, 'REQUEST']])
      expect(conversation.reload.status).to eq('active')
    end

    it 'sends photos of the home it picked as a picture text, with no link' do
      home = company.vehicles.create!(vin: "VIN#{SecureRandom.hex(5)}", year: 2024, make: 'Fleetwood', model: 'Vista', status: 'available', sale_price: 58_023,
                                      images: [{ 'url' => 'https://cdn.example.com/a.jpg' }, { 'url' => 'https://cdn.example.com/b.jpg' }])
      brain_says(reply: 'Here are photos of the 2024 Fleetwood Vista.', photo_home_id: home.id)
      buyer_texts('Can you send me pictures of that one?')
      perform_enqueued_jobs
      expect(sent.last).to include(body: 'Here are photos of the 2024 Fleetwood Vista.',
                                   media_urls: ['https://cdn.example.com/a.jpg', 'https://cdn.example.com/b.jpg'])
      expect(Communication.where(conversation_id: conversation.id).order(:id).last.metadata['media_urls'].size).to eq(2)
    end

    it "texts a home's own link only on a number registered for links" do
      home = company.vehicles.create!(vin: "VIN#{SecureRandom.hex(5)}", year: 2024, make: 'Fleetwood', model: 'Vista', status: 'available')
      allow(Assistant::Media).to receive(:home_url).and_return('https://summit.example.com/homes/2024-fleetwood-vista-1')
      brain_says(reply: 'Here it is: https://summit.example.com/homes/2024-fleetwood-vista-1')
      buyer_texts('Send me the link')
      perform_enqueued_jobs
      expect(sent.map { |m| m[:body] }).not_to include(a_string_including('https://')) # the dealer number is not registered for links
      expect(conversation.reload.status).to eq('handed_off')

      Assistant::Handoff.hand_back!(conversation)
      TwilioAccount.find_by(phone_number: own_number).update!(metadata: { 'links_allowed' => true })
      buyer_texts('Send me the link please')
      perform_enqueued_jobs
      expect(sent.last[:body]).to eq('Here it is: https://summit.example.com/homes/2024-fleetwood-vista-1')

      brain_says(reply: 'See https://other-site.example.com/deal')
      buyer_texts('anything else?')
      perform_enqueued_jobs
      expect(sent.map { |m| m[:body] }).not_to include(a_string_including('other-site'))
    end

    it 'routes a reply to a pool number by the conversation, since the number names no dealer' do
      Setting.set('Platform', 0, 'assistant_pool', { 'live' => true, 'numbers' => [{ 'number' => '+19704632673', 'messaging_service_sid' => 'MGpool' }] })
      other = company.leads.create!(first_name: 'Ray', last_name: 'B', phone: '3035550199', owner_id: rep.id, sms_inquiry_consent: true, source_id: source.id)
      TwilioAccount.where(company: company).destroy_all
      Assistant::Starter.for(other).send_first_text!(body: 'Hi Ray!')
      pool_conversation = Conversation.find_by(conversable: other)

      brain_says(reply: 'Great question.')
      expect { buyer_texts('Hello?', to: '+19704632673', from: '+13035550199') }.to have_enqueued_job(AssistantReplyJob)
      inbound = Communication.where(direction: 'inbound').last
      expect(inbound).to have_attributes(company_id: company.id, communicable: other, conversation_id: pool_conversation.id)
    end

    it 'hands off when the buyer asks about payments, and tells the rep' do
      rep.update!(phone: '3035550199')
      allow(NotificationService).to receive(:send_sms)
      brain_says(reply: 'Our finance manager will go over that with you. I have asked Jordan to text you.',
                 handoff: true, reason: 'finance_or_credit')
      buyer_texts('What would my payment be?')
      perform_enqueued_jobs

      expect(conversation.reload).to have_attributes(status: 'handed_off', handed_off_to_user_id: rep.id,
                                                     handoff_reason: 'finance_or_credit')
      notice = Notification.find_by(notification_type: 'assistant_handoff', recipient_id: rep.id)
      expect(notice.computed_action_url).to eq("/inbox?c=#{conversation.id}")
      expect(NotificationPreference.get_or_create_for(rep, :assistant_handoff).sms_enabled).to be(true)
      expect(NotificationService).to have_received(:send_sms).with(notice, rep)
    end

    it 'never sends a payment figure or a link: it tries again, then hands off' do
      brain_says(reply: 'That home is about $899 a month with financing.')
      buyer_texts('How much a month?')
      perform_enqueued_jobs

      expect(sent.map { |s| s[:body] }).not_to include(a_string_including('$899'))
      expect(conversation.reload.status).to eq('handed_off')
      expect(sent.last[:body]).to eq('I have asked Jordan to text you directly.')
    end

    it 'gives one answer to several quick texts' do
      brain_says(reply: 'Sure thing.')
      buyer_texts('Hi')
      buyer_texts('Are you open Sunday?')
      before = sent.size
      perform_enqueued_jobs
      expect(sent.size - before).to eq(1)
    end

    it 'steps back when a rep texts in the conversation, and the rep hears the next reply' do
      Assistant::Messenger.deliver!(conversation, body: 'Hi Tia, Jordan here.', sent_by: 'user', user: rep)
      expect(conversation.reload).to have_attributes(status: 'handed_off', handed_off_to_user_id: rep.id, handoff_reason: 'rep_replied')

      expect { buyer_texts('Hi Jordan') }.not_to have_enqueued_job(AssistantReplyJob)
      expect(Notification.where(notification_type: 'sms_reply_received', recipient_id: rep.id)).to exist
    end

    it 'closes the conversation on STOP' do
      buyer_texts('STOP')
      expect(conversation.reload.status).to eq('closed')
      expect(enqueued_jobs.select { |j| j['job_class'] == 'AssistantReplyJob' }).to be_empty
    end
  end

  it 'puts a reply from a lead the assistant is not handling in the inbox, for a person' do
    own_account!
    CommunicationService.send_sms(communicable: lead, to: lead.phone, from: own_number, body: 'Hi Tia, it is Jordan.', sender_user_id: rep.id)
    buyer_texts('Hi Jordan, is Saturday ok?')

    conversation = Conversation.find_by(conversable: lead)
    expect(conversation).to have_attributes(assistant_enabled: false, status: 'active', sender_number: own_number)
    expect(conversation.last_message_preview).to eq('Hi Jordan, is Saturday ok?')
    expect(Communication.where(direction: 'inbound').last.conversation_id).to eq(conversation.id)
    expect(enqueued_jobs.select { |j| j['job_class'] == 'AssistantReplyJob' }).to be_empty
  end

  it 'speaks for the company, never for a website built from a template' do
    company.websites.new(name: 'Coastal Breeze Homes', slug: "cb-#{SecureRandom.hex(3)}", brand: { 'company_name' => 'Coastal Breeze Homes' }).save!(validate: false)
    conversation = Conversation.create!(company: company, conversable: lead, sender_number: own_number, buyer_phone: lead.phone, started_at: Time.current)
    prompt = Assistant::Brain.new(conversation: conversation, settings: Assistant::Settings.for(company), history: []).system_prompt
    expect(prompt).to include(company.name)
    expect(prompt).not_to include('Coastal Breeze')
  end

  describe Assistant::Rules do
    it 'refuses links and payment figures, and allows ordinary prices' do
      expect(described_class.violation('See www.summitpark.com')).to eq('link')
      expect(described_class.violation('Check https://x.co')).to eq('link')
      expect(described_class.violation('About $899 a month')).to eq('finance_figure')
      expect(described_class.violation('Rates start at 6.9% APR')).to eq('finance_figure')
      expect(described_class.violation('The Hawthorne is $89,900 delivered and set.')).to be_nil
      expect(described_class.tidy('Yes — we do')).to eq('Yes, we do')
    end
  end
end
