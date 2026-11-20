# frozen_string_literal: true

require 'rails_helper'

# Proactive Outreach review tools (E105 follow-up, 2026-11-20): clear an
# audience and start over, approve every waiting message at once, see what each
# person did on the results, and a Workqueue section for the people who engaged.
RSpec.describe 'Proactive Outreach review tools', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'Ada', last_name: 'Admin', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }

  def grant!
    TenantModuleOverride.create!(company: company, module_key: 'marketing.proactive_outreach', is_enabled: true)
  end

  def new_lead(name)
    company.leads.create!(first_name: name, last_name: 'L', email: "#{name.downcase}-#{SecureRandom.hex(3)}@example.com", owner_id: admin.id, status: 'new')
  end

  def target(wave, lead, **attrs)
    wave.outreach_targets.create!({ company_id: company.id, lead_id: lead.id, channel: 'email', test_group: 'contact' }.merge(attrs))
  end

  describe 'clearing an audience' do
    before { grant! }

    it 'removes a wave that has not started, with everything chosen and written for it' do
      wave = company.outreach_waves.create!(name: 'W', status: 'review')
      t = target(wave, new_lead('Ann'), status: 'drafted', draft_body: 'Hi.')

      delete "/api/crm/outreach_waves/#{wave.id}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(OutreachWave.exists?(wave.id)).to be(false)
      expect(OutreachTarget.exists?(t.id)).to be(false)
    end

    it 'keeps a wave that has started' do
      wave = company.outreach_waves.create!(name: 'W', status: 'paused', started_at: 1.day.ago)

      delete "/api/crm/outreach_waves/#{wave.id}", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(OutreachWave.exists?(wave.id)).to be(true)
    end

    it 'stops writing messages for a wave cleared part way through' do
      wave = company.outreach_waves.create!(name: 'W', status: 'drafting')
      target(wave, new_lead('Bo'), status: 'selected')
      wave_id = wave.id
      wave.destroy!
      expect(Outreach::Writer).not_to receive(:new)
      OutreachDraftOpenersJob.perform_now(wave_id)
    end
  end

  describe 'approving every message' do
    before { grant! }

    it 'approves what passes, keeps what needs a fix with the reason, and leaves out the ones being edited' do
      wave = company.outreach_waves.create!(name: 'W', status: 'review')
      good = target(wave, new_lead('Cy'), status: 'drafted', draft_subject: 'Leads', draft_body: 'Would a short demo help?')
      text = target(wave, new_lead('Di'), status: 'drafted', channel: 'text', draft_body: 'Would a short demo help?')
      priced = target(wave, new_lead('Ed'), status: 'drafted', draft_body: 'Only $99 per month')
      flagged = target(wave, new_lead('Fy'), status: 'drafted', draft_body: 'Fine words', draft_error: 'fill in every placeholder')
      editing = target(wave, new_lead('Gu'), status: 'drafted', draft_body: 'Would a short demo help?')

      post "/api/crm/outreach_waves/#{wave.id}/approve_all", headers: headers, params: { channel: 'email', except_ids: [editing.id] }.to_json
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['approved']).to eq(1)
      expect(body['held'].map { |h| h['target_id'] }).to contain_exactly(priced.id, flagged.id)
      expect(body['held'].find { |h| h['target_id'] == priced.id }['reason']).to eq('never state a price')

      expect(good.reload).to have_attributes(status: 'approved', approved_by_user_id: admin.id)
      expect(text.reload.status).to eq('drafted')
      expect(editing.reload.status).to eq('drafted')
      expect(priced.reload.status).to eq('drafted')

      post "/api/crm/outreach_waves/#{wave.id}/approve_all", headers: headers, params: {}.to_json
      expect(text.reload.status).to eq('approved')
      expect(editing.reload.status).to eq('approved')
    end

    it 'refuses once the wave has started' do
      wave = company.outreach_waves.create!(name: 'W', status: 'running', started_at: Time.current)
      post "/api/crm/outreach_waves/#{wave.id}/approve_all", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'results per person' do
    before { grant! }

    it 'says what each person did' do
      wave = company.outreach_waves.create!(name: 'W', status: 'running', started_at: 2.days.ago)
      clicker = target(wave, new_lead('Hal'), status: 'sent')
      quiet = target(wave, new_lead('Ivy'), status: 'sent')
      gone = target(wave, new_lead('Jo'), status: 'stopped')
      clicker.record!('sent', channel: 'email', at: 2.days.ago)
      clicker.record!('opened', channel: 'email', at: 1.day.ago)
      clicker.record!('clicked', at: 1.hour.ago)
      quiet.record!('sent', channel: 'email', at: 2.days.ago)
      gone.record!('unsubscribed')

      get "/api/crm/outreach_waves/#{wave.id}/results", headers: headers
      people = response.parsed_body['people'].index_by { |p| p['id'] }
      expect(people[clicker.id]['engaged']).to be(true)
      expect(people[clicker.id]['engagement'].keys).to contain_exactly('opened', 'clicked')
      expect(people[clicker.id]['engagement']['clicked']['count']).to eq(1)
      expect(people[quiet.id]).to include('engaged' => false, 'engagement' => {})
      expect(people[gone.id]['engagement'].keys).to eq(['unsubscribed'])
      expect(people[gone.id]['email']).to be_present
    end
  end

  describe 'the Workqueue section' do
    let(:rep) do
      User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'Rex', last_name: 'Rep', password: 'Pass1234!',
                   company_id: company.id, role: 'sales_rep', status: 'active')
    end

    # The full summary also reads workqueue_activities, a view the test schema
    # does not carry, so ask the same question the summary asks per queue.
    def queues_for(user)
      service = WorkqueueService.new(company: company, user: user)
      WorkqueueService::OUTREACH_QUEUES.reject { |id| service.send(:hidden_queue?, id) }
    end

    def items(queue, user = admin)
      WorkqueueService.new(company: company, user: user, queue_id: queue).items[:items].map { |i| i[:entity_id] }
    end

    it 'puts each person in the most useful queue, once, and leaves out the unsubscribed' do
      grant!
      wave = company.outreach_waves.create!(name: 'W', status: 'running', started_at: 2.days.ago)
      opener = new_lead('Kai')
      clicker = new_lead('Lu')
      replier = new_lead('Mo')
      handed = new_lead('Ned')
      booked = new_lead('Oz')
      unsub = new_lead('Pia')
      held_back = new_lead('Quin')

      target(wave, opener, status: 'sent').record!('opened', at: 1.hour.ago)
      t = target(wave, clicker, status: 'sent')
      t.record!('opened', at: 2.hours.ago)
      t.record!('clicked', at: 1.hour.ago)
      t = target(wave, replier, status: 'replied')
      t.record!('clicked', at: 3.hours.ago)
      t.record!('replied', at: 1.hour.ago)
      target(wave, handed, status: 'replied').record!('handed_off', at: 1.hour.ago)
      t = target(wave, booked, status: 'booked', booked_at: 1.hour.ago)
      t.record!('replied', at: 2.hours.ago)
      t = target(wave, unsub, status: 'stopped')
      t.record!('opened', at: 2.hours.ago)
      t.record!('unsubscribed', at: 1.hour.ago)
      target(wave, held_back, test_group: 'holdout').record!('opened', at: 1.hour.ago)

      expect(items('outreach_needs_you')).to eq([handed.id])
      expect(items('outreach_replied')).to eq([replier.id])
      expect(items('outreach_clicked')).to eq([clicker.id])
      expect(items('outreach_opened')).to eq([opener.id])
      expect(items('outreach_booked')).to eq([booked.id])

      WorkqueueDismissal.dismiss!(company: company, user: admin, entity_type: 'Lead', entity_id: replier.id)
      expect(items('outreach_replied')).to eq([])
      expect(items('outreach_clicked')).to eq([clicker.id])
    end

    it 'shows only with the add-on, and only to admins and the outreach sender' do
      expect(WorkqueueService::GROUPS.find { |g| g[:id] == 'outreach' }[:queue_ids]).to eq(WorkqueueService::OUTREACH_QUEUES)
      expect(queues_for(admin)).to eq([])
      grant!
      expect(queues_for(admin)).to eq(WorkqueueService::OUTREACH_QUEUES)
      expect(queues_for(rep)).to eq([])

      Outreach::Settings.for(company).update!('sender_user_id' => rep.id)
      expect(queues_for(rep)).to eq(WorkqueueService::OUTREACH_QUEUES)
    end
  end
end
