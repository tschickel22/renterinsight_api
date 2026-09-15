# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Plays::LeadResponsePlay do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { Company.create!(name: "Summit Park #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:main_location) { company.locations.find_by(is_default: true) }
  let!(:second_location) do
    Location.create!(company_id: company.id, name: 'Aurora Lot', code: "AUR-#{SecureRandom.hex(2)}", active: true)
  end

  def make_user(role: 'sales_rep')
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Rep', last_name: SecureRandom.hex(2),
                 password: 'Pass1234!', company_id: company.id, role: role, status: 'active')
  end

  let(:manager) { make_user(role: 'admin') }
  let(:main_rep) { make_user }
  let(:aurora_rep) { make_user }
  let(:reps) { { main_location.id.to_s => [main_rep.id], second_location.id.to_s => [aurora_rep.id] } }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(described_class).to receive(:texting_ready?).and_return(true)
    allow(CommunicationService).to receive(:send_email).and_return({ success: true })
    allow(CommunicationService).to receive(:send_sms).and_return({ success: true })
  end

  def install(play, answers = {})
    play.new(company: company, user: manager, answers: { 'reps_by_location' => reps }.merge(answers)).install!
  end

  # Runs steps until the run pauses on something that has not come due.
  def advance(run)
    40.times do
      run.reload
      due = %w[pending running].include?(run.status) ||
            (run.status == 'waiting' && run.wait_until.present? && run.wait_until <= Time.current)
      break unless due
      ProcessWorkflowStepJob.perform_now(run.id)
    end
    run.reload
  end

  def run_for(lead)
    DispatchWorkflowEventsJob.new.perform
    WorkflowRun.where(entity_type: 'Lead', entity_id: lead.id).order(:id).first
  end

  def source(name)
    company.sources.find_by(name: name)
  end

  describe Plays::NewFacebookLead do
    it 'switches on a valid workflow, its form, rotations and follow-up emails' do
      installation = install(described_class)

      # A new-lead rule, and one for its starting tag.
      rules = WorkflowRule.where(id: installation.asset_ids(:workflow_rule_ids))
      expect(rules.map(&:status)).to eq(%w[active active])
      new_lead = rules.find { |rule| rule.trigger['event_type'] == 'lead.created' }
      expect(WorkflowRuleValidator.new(new_lead).validate).to be_valid
      expect(new_lead.conditions.first['value']).to eq(['Facebook'])

      form = IntakeForm.find(installation.asset_ids(:intake_form_ids).first)
      expect(form).to have_attributes(name: 'Facebook Contact', is_active: true)
      expect(form.source.name).to eq('Facebook')

      sequence = NurtureSequence.find(installation.asset_ids(:nurture_sequence_ids).first)
      expect(sequence.nurture_steps.order(:position).pluck(:step_type)).to eq(%w[email email email])
      expect(installation.asset_ids(:round_robin_list_ids).size).to eq(3)
    end

    it "sends a Facebook lead to its location's rep: text, email, call within 15 minutes, then waits" do
      install(described_class)
      lead = Lead.create!(company_id: company.id, source_id: source('Facebook').id, location_id: second_location.id,
                          first_name: 'Tia', last_name: 'May', email: 'tia@example.com', phone: '3035551212', opt_in_sms: true)

      run = advance(run_for(lead))

      expect(lead.reload.owner_id).to eq(aurora_rep.id)
      expect(CommunicationService).to have_received(:send_sms).with(hash_including(body: a_string_including("Hi Tia, this is Rep")))
      expect(CommunicationService).to have_received(:send_email).once
      call = LeadActivity.where(lead_id: lead.id, activity_type: 'call').last
      expect(call.due_date).to be_within(2.minutes).of(15.minutes.from_now)
      expect(run).to have_attributes(status: 'waiting', wait_reason: 'reply_pause')
    end
  end

  describe Plays::WalkInVisit do
    it 'keeps the lead with the rep who entered it, waits two hours, then texts and sets a call for the next morning' do
      install(described_class)
      entered_by = make_user
      lead = Lead.create!(company_id: company.id, source_id: source('Walk-In').id, location_id: main_location.id,
                          owner_id: entered_by.id, first_name: 'Sam', last_name: 'Lee', email: 'sam@example.com',
                          phone: '3035550000', opt_in_sms: true)

      run = advance(run_for(lead))
      expect(run.wait_reason).to eq('delay')
      expect(CommunicationService).not_to have_received(:send_sms)

      travel 3.hours do
        run = advance(run)
        expect(lead.reload.owner_id).to eq(entered_by.id)
        expect(CommunicationService).to have_received(:send_sms).with(hash_including(body: a_string_including('Great meeting you today')))
        call = LeadActivity.where(lead_id: lead.id, activity_type: 'call').last
        expect(call.due_date.to_date).to eq(Date.current + 1)
        expect(call.due_date.hour).to eq(10)
        expect(run.wait_reason).to eq('reply_pause')
      end
    end

    it 'gives an unassigned walk-in to the rotation' do
      install(described_class)
      lead = Lead.create!(company_id: company.id, source_id: source('Walk-In').id, location_id: main_location.id,
                          first_name: 'Sam', last_name: 'Lee', email: 'sam@example.com')

      advance(run_for(lead))

      expect(lead.reload.owner_id).to eq(main_rep.id)
    end
  end

  describe 'customizing' do
    it 'rewrites the workflow and follow-up emails in place, keeping the same rotations' do
      installation = install(Plays::NewFacebookLead)
      rotation_ids = installation.asset_ids(:round_robin_list_ids).sort
      content = Plays::NewFacebookLead.default_content.deep_dup
      content['first_text']['body'] = 'Hey {{first_name}}! {{rep_name}} here from {{dealership}}.'
      content['reply_wait_hours'] = 12
      content['follow_up_emails'] = [
        { 'day' => 2, 'subject' => 'Checking in, {{first_name}}', 'body' => 'Still looking?', 'include_homes' => true }
      ]

      Plays::NewFacebookLead.new(company: company, user: manager, installation: installation,
                                 answers: { 'reps_by_location' => reps, 'content' => content }).customize!

      rule = WorkflowRule.find(installation.asset_ids(:workflow_rule_ids).first)
      nodes = rule.steps['nodes'].index_by { |n| n['id'] }
      expect(nodes['text_hello']['config']['body']).to eq("Hey {{entity.first_name}}! {{entity.owner_name}} here from #{company.name}.")
      expect(nodes['wait_reply']['config']['timeout_hours']).to eq(12)
      expect(rule.status).to eq('active')

      steps = NurtureSequence.find(installation.asset_ids(:nurture_sequence_ids).first).nurture_steps.order(:position)
      expect(steps.map { |s| [s.step_type, s.wait_days.to_i] }).to eq([['wait', 0], ['email', 2]])
      expect(steps.last.subject).to eq('Checking in, {{first_name}}')
      expect(installation.reload.asset_ids(:round_robin_list_ids).sort).to eq(rotation_ids)
    end

    it 'refuses a field the message cannot fill' do
      content = Plays::NewFacebookLead.default_content.deep_dup
      content['first_text']['body'] = 'Hi {{favorite_color}}'

      expect { install(Plays::NewFacebookLead, 'content' => content) }.to raise_error(Plays::InstallError, /favorite_color/)
    end
  end

  it 'will not let two plays start from the same source' do
    install(Plays::NewFacebookLead)

    expect { install(Plays::WalkInVisit, 'sources' => ['Facebook']) }
      .to raise_error(Plays::InstallError, /already starts New Facebook lead/)
  end

  it 'draws the play with each message previewed on sample values' do
    map = Plays::NewFacebookLead.definition(company)[:map]

    expect(map.map { |s| s[:key] }).to eq(%w[trigger assign first_text first_email call_task reply_wait weekly_homes])
    expect(map.find { |s| s[:key] == 'first_text' }[:preview]).to include('Hi Tia', company.name)
    no_reply = map.find { |s| s[:key] == 'reply_wait' }[:branches].find { |b| b[:key] == 'no_reply' }
    expect(no_reply[:steps].size).to eq(3)
  end

  describe 'a retired New lead, any channel install' do
    let(:legacy) do
      PlayInstallation.create!(company_id: company.id, play_key: 'new_lead_any_channel', status: 'active',
                               answers: { 'channels' => %w[facebook google] }, assets: {}, installed_at: Time.current)
    end

    it 'still claims its sources and can be turned off' do
      legacy

      expect(Plays::NewLeadAnyChannel.answers_for(legacy)['sources']).to eq(%w[Facebook Google])
      expect { install(Plays::NewFacebookLead) }.to raise_error(Plays::InstallError, /New lead, any channel/)

      Plays::NewLeadAnyChannel.uninstall!(legacy)
      expect(install(Plays::NewFacebookLead).status).to eq('active')
    end
  end
end
