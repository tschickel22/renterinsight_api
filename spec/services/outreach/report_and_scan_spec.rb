# frozen_string_literal: true

require 'rails_helper'

# The shareable website checkup, the TrueBuild opener video, and a full scan
# request handed to Tom (backlog E105, 2026-11-19).
RSpec.describe 'Outreach website checkup and full scan requests' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:tom) do
    User.create!(email: "t-#{SecureRandom.hex(4)}@example.com", first_name: 'Tom', last_name: 'Schickel', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:settings) { Outreach::Settings.for(company) }
  let(:wave) { company.outreach_waves.create!(name: 'W', status: 'running', started_at: 1.hour.ago) }
  let(:lead) do
    company.leads.create!(first_name: 'Ann', last_name: 'Lee', company_name: 'Sunrise Homes', email: 'ann@sunrisebiloxi.com',
                          phone: '2285550144', owner_id: tom.id, status: 'new', sms_inquiry_consent: true, state: 'MS')
  end
  let(:report) do
    { 'score' => 54, 'ai_score' => 40, 'pages_checked' => 4, 'passed' => 9, 'meaning' => 'In practice, buyers may not find this dealership.',
      'areas' => [{ 'label' => 'Homes marked up for search', 'status' => 'fail', 'affected_count' => 3,
                    'consequence' => 'individual homes are not described in a form search engines can read' }] }
  end
  let(:target) do
    wave.outreach_targets.create!(company_id: company.id, lead_id: lead.id, channel: 'text', status: 'sent',
                                  site_research: { 'status' => 'found', 'url' => 'https://www.sunrisebiloxi.com', 'report' => report })
  end

  before do
    TenantModuleOverride.create!(company: company, module_key: 'marketing.proactive_outreach', is_enabled: true)
    settings.update!('enabled' => true, 'persona_name' => 'Tom Schickel', 'sender_user_id' => tom.id, 'postal_address' => '1 Main St')
  end

  it 'keeps which pages and how to fix them out of the shareable report' do
    seo = { 'score' => 54, 'ai_score' => 40, 'pages_checked' => 4, 'checks' => [
      { 'key' => 'structured_data', 'label' => 'Homes marked up', 'status' => 'fail', 'headline' => 'Add JSON-LD to /homes/1',
        'detail' => 'Put Product schema in the head', 'urls' => %w[https://x.com/homes/1 https://x.com/homes/2], 'category' => 'seo' },
      { 'key' => 'titles', 'label' => 'Titles', 'status' => 'pass', 'urls' => [], 'category' => 'seo' }
    ] }
    shared = Outreach::SiteResearch.new(target).send(:shareable_report, seo)
    expect(shared.to_json).not_to include('x.com/homes', 'JSON-LD', 'Product schema')
    expect(shared['areas'].first).to include('label' => 'Homes marked up', 'affected_count' => 2)
    expect(shared['areas'].first['consequence']).to include('search engines can read')
    expect(shared['passed']).to eq(1)
  end

  it 'adds the checkup link only when asked, after the opener, and only once' do
    allow(Outreach::Clock).to receive(:send_now?).and_return(true)
    allow(Assistant::Messenger).to receive(:deliver!) { |_c, body:, **| { success: true, communication: nil, body: body } }
    TwilioAccount.create!(company_id: company.id, account_sid: 'AC1', auth_token: 'x', phone_number: '+17204632132', status: 'active') rescue nil

    Outreach::Sender.new(target).deliver!(body: 'Here is a quick look.', channel: 'text', kind: 'follow_up', report: true)
    expect(Assistant::Messenger).to have_received(:deliver!).with(anything, hash_including(body: a_string_including('Your website checkup: ', '/o/r/')))
    expect(target.reload.site_research['report_shared_at']).to be_present

    writer = Outreach::Writer.new(target)
    writer.instance_variable_set(:@task_kind, 'follow_up')
    expect(writer.send(:report_offerable?)).to be(false)
    writer.instance_variable_set(:@task_kind, 'opener')
    target.update!(site_research: target.site_research.except('report_shared_at'))
    expect(Outreach::Writer.new(target).tap { |w| w.instance_variable_set(:@task_kind, 'opener') }.send(:report_offerable?)).to be(false)
  end

  it 'opens with the TrueBuild video whatever the AI picked' do
    other = company.outreach_content_items.create!(title: 'Inventory tour', url: 'https://vimeo.com/1', status: 'approved')
    truebuild = company.outreach_content_items.create!(title: 'TrueBuild: let buyers design a home', url: 'https://vimeo.com/2', status: 'approved')
    allow(Outreach::AiClient).to receive(:call).and_return('body' => 'Hi Ann, quick question about your lot.', 'content_id' => "C#{other.id}")
    allow(Outreach::Guard).to receive(:violation).and_return(nil)

    result = Outreach::Writer.new(target).opener('text')
    expect(result.content_item).to eq(truebuild)
    expect(result.share_report).to be(false)
  end

  it 'hands a full scan request to Tom as a task' do
    conversation = company.conversations.create!(conversable: lead, sender_number: '+17204632132', buyer_phone: lead.phone,
                                                 assigned_user_id: tom.id, started_at: Time.current)
    target.update!(conversation: conversation)
    allow(Assistant::Handoff).to receive(:notify)

    Outreach::Handoff.perform!(target, reason: 'wants_site_scan', summary: 'They want to see their site with TrueBuild.')
    task = lead.lead_activities.find_by(activity_type: 'task')
    expect(task).to have_attributes(assigned_to_id: tom.id, priority: 'high')
    expect(task.subject).to include('full site scan', 'Sunrise Homes')
    expect(task.description).to include('https://www.sunrisebiloxi.com')
    expect(target.recorded?('scan_requested')).to be(true)
    expect(conversation.reload.status).to eq('handed_off')
  end
end
