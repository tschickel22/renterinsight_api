# frozen_string_literal: true

require 'rails_helper'

# Every lead response play can be started by a tag the dealer chooses.
RSpec.describe Plays::LeadResponsePlay, 'starting tag' do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit Park #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:location) { company.inbound_lead_location }

  def make_user(role: 'sales_rep')
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Rep', last_name: SecureRandom.hex(2),
                 password: 'Pass1234!', company_id: company.id, role: role, status: 'active')
  end

  let(:manager) { make_user(role: 'admin') }
  let(:rep) { make_user }
  let(:reps) { { location.id.to_s => [rep.id] } }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(described_class).to receive(:texting_ready?).and_return(false)
    allow(CommunicationService).to receive(:send_email).and_return({ success: true })
  end

  def install(play, answers = {})
    play.new(company: company, user: manager, answers: { 'reps_by_location' => reps }.merge(answers)).install!
  end

  def customize(play, installation, answers)
    play.new(company: company, user: manager, installation: installation,
             answers: play.answers_for(installation).merge(answers)).customize!
  end

  def tag_rules(installation)
    WorkflowRule.where(id: installation.reload.asset_ids(:workflow_rule_ids)).select { |r| r.trigger['event_type'] == 'lead.tagged' }
  end

  it 'gives New Facebook lead a starting tag, and tagging a lead starts the play' do
    installation = install(Plays::NewFacebookLead)
    rule = tag_rules(installation).first

    expect(Plays::NewFacebookLead.answers_for(installation)['start_tag']).to eq('facebook-lead')
    expect(rule.conditions).to eq([{ 'field' => 'trigger.tag_name', 'operator' => 'equals', 'value' => 'facebook-lead' }])
    expect(Plays::NewFacebookLead.installation_json(installation)[:map].first[:detail]).to include('tags a lead facebook-lead')

    lead = Lead.create!(company_id: company.id, first_name: 'Tia', last_name: 'May', email: 'tia@example.com')
    DispatchWorkflowEventsJob.new.perform
    tag = company.tags.find_by!(name: 'facebook-lead')
    TagAssignment.create!(company_id: company.id, tag: tag, entity_type: 'Lead', entity_id: lead.id, assigned_at: Time.current)
    DispatchWorkflowEventsJob.new.perform

    expect(WorkflowRun.where(entity_type: 'Lead', entity_id: lead.id, workflow_rule_id: rule.id)).to exist
  end

  it 'takes a tag the dealer types, or none' do
    typed = install(Plays::NewFacebookLead, 'start_tag' => ' Hot Lead! ')
    expect(Plays::NewFacebookLead.answers_for(typed)['start_tag']).to eq('hot-lead')

    walk_in = install(Plays::WalkInVisit, 'start_tag' => '')
    expect(Plays::WalkInVisit.answers_for(walk_in)['start_tag']).to be_nil
    expect(tag_rules(walk_in)).to be_empty
  end

  it 'adds, changes and removes the tagged start on customize' do
    installation = install(Plays::WalkInVisit, 'start_tag' => '')

    customize(Plays::WalkInVisit, installation, 'start_tag' => 'showroom')
    rule = tag_rules(installation).first
    expect(rule).to have_attributes(status: 'active', name: 'Walk-in visit: tagged showroom')

    customize(Plays::WalkInVisit, installation, 'start_tag' => 'lot-visit')
    expect(rule.reload.conditions.first['value']).to eq('lot-visit')
    expect(tag_rules(installation).map(&:id)).to eq([rule.id])

    customize(Plays::WalkInVisit, installation, 'start_tag' => '')
    expect(rule.reload.status).to eq('archived')
  end

  it "refuses another play's tag and the weekly homes email tag" do
    install(Plays::WalkInVisit)

    expect { install(Plays::NewFacebookLead, 'start_tag' => 'walk-in') }
      .to raise_error(Plays::InstallError, /walk-in already starts Walk-in visit/)
    expect { install(Plays::NewFacebookLead, 'start_tag' => 'weekly-digest-email') }
      .to raise_error(Plays::InstallError, /weekly homes email tag/)
  end

  it 'keeps the preset tag for installs saved before the tag was editable' do
    installation = install(Plays::WalkInVisit)
    installation.update_column(:answers, installation.answers.except('start_tag'))

    expect(Plays::WalkInVisit.answers_for(installation.reload)['start_tag']).to eq('walk-in')
  end
end
