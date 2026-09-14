# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Plays::NewLeadAnyChannel do
  include ActiveJob::TestHelper

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

  let(:answers) do
    {
      'channels' => %w[website facebook],
      'reps_by_location' => { main_location.id.to_s => [main_rep.id], second_location.id.to_s => [aurora_rep.id] },
      'call_within_minutes' => 15,
      'send_texts' => true
    }
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(described_class).to receive(:texting_ready?).and_return(true)
    allow(CommunicationService).to receive(:send_email).and_return({ success: true })
    allow(CommunicationService).to receive(:send_sms).and_return({ success: true })
  end

  def install!(overrides = {})
    described_class.new(company: company, user: manager, answers: answers.merge(overrides)).install!
  end

  def run_until_it_waits(run)
    25.times do
      break unless %w[pending running].include?(run.reload.status)
      ProcessWorkflowStepJob.perform_now(run.id)
    end
    run.reload
  end

  describe 'installing' do
    it 'switches on both workflows, each passing validation' do
      installation = install!

      rules = WorkflowRule.where(id: installation.asset_ids(:workflow_rule_ids))
      expect(rules.map(&:status)).to eq(%w[active active])
      rules.each { |rule| expect(WorkflowRuleValidator.new(rule).validate).to be_valid }
      expect(rules.map { |r| r.trigger['event_type'] }).to contain_exactly('lead.created', 'lead.tagged')
    end

    it 'creates a form per channel with its own source and a text consent field' do
      installation = install!

      forms = IntakeForm.where(id: installation.asset_ids(:intake_form_ids))
      expect(forms.map { |f| f.source.name }).to contain_exactly('Website', 'Facebook')
      consent = forms.first.schema.find { |field| field['leadField'] == 'opt_in_sms' }
      expect(consent['type']).to eq('consent')
      expect(consent['consentText']).to include('Reply STOP')
    end

    it 'creates a nurture that stops when the lead replies or converts' do
      sequence = NurtureSequence.find(install!.asset_ids(:nurture_sequence_ids).first)

      expect(sequence).to have_attributes(is_active: true, stop_on_reply: true, stop_on_conversion: true)
      expect(sequence.nurture_steps.pluck(:step_type).uniq).to eq(['email'])
    end

    it 'refuses a second install while the play is on' do
      install!

      expect { install! }.to raise_error(Plays::InstallError, /already on/)
    end

    it "ignores reps who are not this company's" do
      other = Company.create!(name: "Other #{SecureRandom.hex(3)}", industry: 'manufactured_housing')
      outsider = User.create!(email: "x-#{SecureRandom.hex(4)}@example.com", first_name: 'X', last_name: 'Y',
                              password: 'Pass1234!', company_id: other.id, role: 'sales_rep', status: 'active')

      expect { install!('reps_by_location' => { main_location.id.to_s => [outsider.id] }) }
        .to raise_error(Plays::InstallError, /at least one rep/)
    end
  end

  describe 'a new website lead' do
    let(:installation) { install! }
    let(:website_source) { company.sources.find_by(name: 'Website') }

    def new_lead(opt_in_sms:)
      installation
      Lead.create!(company_id: company.id, source_id: website_source.id, location_id: second_location.id,
                   first_name: 'Tia', last_name: 'May', email: 'tia@example.com', phone: '3035551212',
                   opt_in_sms: opt_in_sms)
    end

    def start(lead)
      DispatchWorkflowEventsJob.new.perform
      run = WorkflowRun.where(entity_type: 'Lead', entity_id: lead.id).order(:id).first
      run_until_it_waits(run)
    end

    it "goes to that location's rep, gets a text and email, a call task, and waits for a reply" do
      lead = new_lead(opt_in_sms: true)

      run = start(lead)

      expect(lead.reload.owner_id).to eq(aurora_rep.id)
      expect(CommunicationService).to have_received(:send_sms).once
      expect(CommunicationService).to have_received(:send_email).once
      call = LeadActivity.where(lead_id: lead.id, activity_type: 'call').last
      expect(call.assigned_to_id).to eq(aurora_rep.id)
      expect(call.due_date).to be_within(2.minutes).of(15.minutes.from_now)
      expect(run).to have_attributes(status: 'waiting', wait_reason: 'reply_pause')
    end

    it 'is not texted without consent, but still gets the email' do
      start(new_lead(opt_in_sms: false))

      expect(CommunicationService).not_to have_received(:send_sms)
      expect(CommunicationService).to have_received(:send_email).once
    end

    it 'stops cleanly when the play is turned off' do
      run = start(new_lead(opt_in_sms: true))

      described_class.uninstall!(installation)

      expect(run.reload.status).to eq('cancelled')
      expect(WorkflowRule.where(id: installation.asset_ids(:workflow_rule_ids)).pluck(:status).uniq).to eq(['archived'])
      expect(IntakeForm.where(id: installation.asset_ids(:intake_form_ids)).pluck(:is_active).uniq).to eq([false])
      expect(RoundRobinAssignmentList.where(id: installation.asset_ids(:round_robin_list_ids)).pluck(:active).uniq).to eq([false])
      expect(installation.reload.status).to eq('uninstalled')
    end
  end
end
