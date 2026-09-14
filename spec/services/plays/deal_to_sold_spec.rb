# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Plays::DealToSold do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { Company.create!(name: "Summit Park #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:location) { company.inbound_lead_location }

  def make_user(role: 'sales_rep')
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: role, status: 'active')
  end

  let(:manager) { make_user(role: 'admin') }
  let(:rep) { make_user }
  let(:buyer) { Contact.create!(company_id: company.id, first_name: 'Tia', last_name: 'May', email: 'tia@example.com') }
  let(:no_email) { Contact.create!(company_id: company.id, first_name: 'Sam', last_name: 'Cole') }
  let(:review) do
    { 'enabled' => true, 'day' => 30, 'subject' => 'How did we do?', 'body' => 'Hi {{first_name}}',
      'review_link' => 'https://g.page/r/summit/review' }
  end
  let(:proposal_task) { { 'stage' => 'proposal', 'subject' => 'Send {{buyer_name}} the proposal', 'due_days' => 2 } }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(CommunicationService).to receive(:send_email).and_return({ success: true })
  end

  def install(content = {})
    described_class.new(company: company, user: manager, answers: { 'content' => content }).install!
  end

  def deal_for(contact, stage: 'negotiation')
    Deal.create!(company_id: company.id, location_id: location.id, name: 'Tia May, Tru Buttercup', stage: stage,
                 contact: contact, owner_id: rep.id, value: 90_000)
  end

  def runs_for(deal)
    DispatchWorkflowEventsJob.new.perform
    WorkflowRun.where(entity_type: 'Deal', entity_id: deal.id).order(:id).to_a
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

  describe '#install!' do
    it 'switches on a valid rule for wins, one for each chosen stage, and one for losses' do
      installation = install('review_request' => review, 'stage_tasks' => [proposal_task])
      rules = WorkflowRule.where(id: installation.asset_ids(:workflow_rule_ids))

      expect(rules.map(&:status).uniq).to eq(['active'])
      expect(rules.map(&:entity_type).uniq).to eq(['Deal'])
      expect(rules.map { |r| r.trigger['event_type'] }).to contain_exactly('deal.won', 'deal.lost', 'deal.status_changed')
      stage_rule = rules.find { |r| r.trigger['event_type'] == 'deal.status_changed' }
      expect(stage_rule.conditions).to eq([{ 'field' => 'trigger.to', 'operator' => 'equals', 'value' => 'proposal' }])

      branches = described_class.installation_json(installation)[:map].first[:branches]
      expect(branches.map { |b| b[:label] }).to eq(['Won (Closed Won)', 'Reaches a stage you chose', 'Lost'])
      expect(branches.first[:steps].map { |s| s[:key] }).to eq(%w[thank_you check_in review_request referral_ask])
    end

    it 'refuses a review request with no link, a won stage task, an unknown field, and nothing turned on' do
      expect { install('review_request' => review.merge('review_link' => '')) }.to raise_error(Plays::InstallError, /review/)
      expect { install('stage_tasks' => [proposal_task.merge('stage' => 'closed_won')]) }
        .to raise_error(Plays::InstallError, /stage from your pipeline/)
      expect { install('check_in' => { 'enabled' => true, 'day' => 3, 'subject' => 'Call {{rep_phone}}' }) }
        .to raise_error(Plays::InstallError, /\{\{rep_phone\}\} can't be used/)

      nothing = %w[thank_you check_in review_request referral_ask lost_check_in].to_h { |key| [key, { 'enabled' => false }] }
      expect { install(nothing) }.to raise_error(Plays::InstallError, /at least one part/)
    end
  end

  describe 'a won deal' do
    it 'thanks the buyer, gives the rep a check-in, asks for a review and a referral, then marks the deal done' do
      install('review_request' => review)
      deal = deal_for(buyer)
      start = Time.current
      deal.update!(stage: 'closed_won')
      run = runs_for(deal).first

      advance(run)
      expect(CommunicationService).to have_received(:send_email)
        .with(hash_including(to: 'tia@example.com', subject: 'Thank you, Tia'))
      # A waiting run already points at the step the wait leads to.
      expect(run).to have_attributes(status: 'waiting', current_step_id: 'check_in')

      travel_to(start + 7.days + 1.hour) { advance(run) }
      expect(DealActivity.where(deal_id: deal.id).pluck(:activity_type, :subject, :assigned_to_id))
        .to eq([['call', 'Check in with Tia May', rep.id]])

      travel_to(start + 30.days + 2.hours) { advance(run) }
      expect(CommunicationService).to have_received(:send_email)
        .with(hash_including(subject: 'How did we do?', body: include('https://g.page/r/summit/review')))

      travel_to(start + 60.days + 3.hours) { advance(run) }
      expect(CommunicationService).to have_received(:send_email).with(hash_including(subject: 'Know someone looking for a home?'))
      expect(run.status).to eq('completed')
      expect(deal.reload.tags.pluck(:name)).to include('after-sale-done')
    end

    it "skips buyer emails when the deal's contact has no email, and still gives the rep the check-in" do
      install('check_in' => { 'enabled' => true, 'day' => 0, 'subject' => 'Call {{buyer_name}}' },
              'referral_ask' => { 'enabled' => false })
      deal = deal_for(no_email)
      deal.update!(stage: 'closed_won')
      run = advance(runs_for(deal).first)

      expect(run.status).to eq('completed')
      expect(CommunicationService).not_to have_received(:send_email)
      expect(DealActivity.where(deal_id: deal.id).count).to eq(1)
    end
  end

  describe 'stage and lost tasks' do
    it 'gives the rep a task at a chosen stage and a check-back when the deal is lost' do
      install('stage_tasks' => [proposal_task])
      deal = deal_for(buyer, stage: 'qualification')

      deal.update!(stage: 'proposal')
      runs_for(deal).each { |run| advance(run) }
      task = DealActivity.find_by(deal_id: deal.id, activity_type: 'task')
      expect(task).to have_attributes(subject: 'Send Tia May the proposal', assigned_to_id: rep.id)
      expect(task.due_date.to_date).to eq(Date.current + 2.days)

      deal.update!(stage: 'closed_lost')
      runs_for(deal).each { |run| advance(run) }
      expect(DealActivity.where(deal_id: deal.id, activity_type: 'task').pluck(:subject))
        .to contain_exactly('Send Tia May the proposal', 'Check back with Tia May')
    end
  end

  describe '#customize!' do
    it 'updates the won rule in place, moves stage tasks, and turns parts off' do
      installation = install('stage_tasks' => [proposal_task])
      rules = installation.assets['rules']

      content = described_class.answers_for(installation)['content'].merge(
        'stage_tasks' => [{ 'stage' => 'negotiation', 'subject' => 'Price check for {{deal_name}}', 'due_days' => 0 }],
        'lost_check_in' => { 'enabled' => false }
      )
      described_class.new(company: company, user: manager, installation: installation, answers: { 'content' => content }).customize!

      installation.reload
      expect(installation.assets['rules']['won']).to eq(rules['won'])
      expect(installation.assets['rules']['stages'].keys).to eq(['negotiation'])
      expect(installation.assets['rules']['lost']).to be_nil
      expect(WorkflowRule.find(rules['stages']['proposal']).status).to eq('archived')
      expect(WorkflowRule.find(rules['lost']).status).to eq('archived')
      expect(described_class.installation_json(installation)[:workflow_rules].size).to eq(2)
    end
  end

  describe '.uninstall!' do
    it 'archives the rules and cancels follow-up still waiting' do
      installation = install
      deal = deal_for(buyer)
      deal.update!(stage: 'closed_won')
      run = advance(runs_for(deal).first)

      described_class.uninstall!(installation)

      expect(run.reload.status).to eq('cancelled')
      expect(WorkflowRule.where(id: installation.asset_ids(:workflow_rule_ids)).pluck(:status).uniq).to eq(['archived'])
    end
  end

  describe 'results' do
    it 'counts what went out, lists each deal, and tells its journey' do
      installation = install('stage_tasks' => [proposal_task])
      won = deal_for(buyer)
      won.update!(stage: 'closed_won')
      runs_for(won).each { |run| advance(run) }
      other = deal_for(no_email, stage: 'qualification')
      other.update!(stage: 'proposal')
      runs_for(other).each { |run| advance(run) }

      summary = described_class.performance_for(installation, period: '30', location_ids: nil)
      expect(summary[:stage_counts]).to include('after_sale' => 1, 'in_pipeline' => 1)
      expect(summary[:step_counts]).to eq('check_in' => 1)
      expect(summary[:metrics]).to include(deals_won: 1, thank_yous_sent: 1, check_ins: 0, stage_tasks: 1, stage_tasks_done: 0)

      list = described_class.leads_for(installation, period: '30', location_ids: nil, stage: 'after_sale', page: 1, per_page: 25)
      expect(list[:items].first).to include(lead_id: won.id, record_path: "/deals/#{won.id}",
                                            detail: 'Next: Check-in call for the rep on')
      expect(described_class.leads_for(installation, period: '30', location_ids: [0], stage: nil, page: 1, per_page: 25)[:meta][:total]).to eq(0)

      journey = described_class.lead_journey_for(installation, won, location_ids: nil)
      expect(journey[:events].map { |e| e[:kind] }).to eq(%w[deal email wait])
      expect(described_class.lead_journey_for(installation, won, location_ids: [0])).to be_nil
    end
  end
end
