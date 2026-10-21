# frozen_string_literal: true

require 'rails_helper'

# A lead play runs on one intake form: one the dealer already has (the form on
# their website), or one it creates. Either way the form decides who owns a new
# lead, and the play uses the form's rotation rather than keeping a second one.
RSpec.describe 'Plays on an existing intake form' do
  let(:company) { Company.create!(name: "Easy #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:other_company) { Company.create!(name: "Platform #{SecureRandom.hex(3)}", industry: 'saas') }
  let(:location) { company.locations.find_by(is_default: true) }

  def make_user(name, company_id: company.id)
    User.create!(email: "#{name}-#{SecureRandom.hex(4)}@example.com", first_name: name.capitalize, last_name: 'Rep',
                 password: 'Pass1234!', company_id: company_id, role: 'sales_rep', status: 'active')
  end

  let!(:payton) { make_user('payton') }
  let!(:mike) { make_user('mike') }
  let(:reps) { { location.id.to_s => [mike.id, payton.id] } }

  let(:site_source) { company.sources.create!(name: 'Website Contact (easyhomes.com)', is_active: true) }
  let!(:site_form) do
    IntakeForm.create!(company_id: company.id, name: 'Website Contact', source_id: site_source.id, is_active: true,
                       auto_create_lead: true, auto_create_activity: true, notified_user_id: payton.id,
                       marketing_consent_enabled: false,
                       schema: [{ 'name' => 'Email', 'type' => 'email', 'leadField' => 'email' }])
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Plays::LeadResponsePlay).to receive(:texting_ready?).and_return(false)
  end

  def install(answers, user = payton)
    Plays::NewWebsiteLead.new(company: company, user: user, answers: answers).install!
  end

  def customize(installation, answers)
    Plays::NewWebsiteLead.new(company: company, user: payton, installation: installation,
                              answers: Plays::NewWebsiteLead.answers_for(installation).merge(answers)).customize!
  end

  def assign_steps(installation)
    rule = WorkflowRule.find(Array(installation.assets['workflow_rule_ids']).first)
    rule.steps['nodes'].select { |node| node['type'] == 'assign_owner' }
  end

  it 'suggests the form the website submits to' do
    site = company.websites.create!(location_id: location.id, name: 'Easy', slug: "s-#{SecureRandom.hex(4)}")
    site.website_pages.create!(title: 'Contact', blocks: [{ 'type' => 'contact', 'props' => { 'formId' => site_form.id.to_s } }])
    IntakeForm.create!(company_id: company.id, name: 'Contact Us', is_active: true, schema: site_form.schema)

    expect(Plays::NewWebsiteLead.suggested_form_for(company)).to eq(site_form)
    choice = Plays::NewWebsiteLead.form_choices(company).find { |c| c[:id] == site_form.id }
    expect(choice[:on_website]).to be true
  end

  it 'runs on the chosen form instead of making a second one, and puts its rotation on that form' do
    expect { install('reps_by_location' => reps, 'intake_form_id' => site_form.id) }
      .not_to(change { company.intake_forms.count })
    installation = PlayInstallation.active.find_by!(company_id: company.id, play_key: Plays::NewWebsiteLead::KEY)

    site_form.reload
    expect(site_form.rotates?).to be true
    expect(site_form.rotation_user_ids).to eq([mike.id, payton.id])
    # The play makes the call task, and texts only a lead who ticked the consent box.
    expect(site_form.auto_create_activity).to be false
    expect(site_form.marketing_consent_enabled).to be true
    expect(Plays::NewWebsiteLead.answers_for(installation)['sources']).to include(site_source.name)
    # The form already gave the lead a rep; the play keeps them.
    rule = WorkflowRule.find(Array(installation.assets['workflow_rule_ids']).first)
    expect(rule.steps['nodes'].map { |n| n['id'] }).to include('has_owner')
  end

  it 'uses a rotation already on the form, without asking for reps' do
    site_form.update!(assignment_mode: 'round_robin', rotation_user_ids: [payton.id])
    list_id = site_form.round_robin_list_id

    installation = install('reps_by_location' => {}, 'intake_form_id' => site_form.id)

    expect(installation.assets['round_robin_list_ids']).to eq([])
    expect(assign_steps(installation).map { |node| node['config']['round_robin_list_id'] }).to eq([list_id])
    expect(site_form.reload.round_robin_list_id).to eq(list_id)

    json = Plays::NewWebsiteLead.installation_json(installation)
    expect(json[:intake_form_id]).to eq(site_form.id)
    expect(json[:map].find { |step| step[:key] == 'assign' }[:detail]).to include('Payton')

    # Turning the play off leaves the form's own rotation alone.
    Plays::NewWebsiteLead.uninstall!(installation)
    expect(RoundRobinAssignmentList.find(list_id).active).to be true
    expect(site_form.reload.rotates?).to be true
  end

  it 'gives the dealer\'s form its settings back and leaves it on when the play is turned off' do
    installation = install('reps_by_location' => reps, 'intake_form_id' => site_form.id)
    Plays::NewWebsiteLead.uninstall!(installation)

    site_form.reload
    expect(site_form.is_active).to be true
    expect(site_form.auto_create_activity).to be true
    expect(site_form.marketing_consent_enabled).to be false
    expect(site_form.assignment_mode).to be_nil
    expect(site_form.round_robin_list_id).to be_nil
  end

  it 'moves an install from its own form to the website form, turning its own off' do
    installation = install('reps_by_location' => reps, 'intake_form_id' => 'new')
    own = IntakeForm.find(installation.assets['intake_form_ids'].first)
    expect(own.name).to eq('Website Contact (2)')
    expect(own.rotates?).to be true

    customize(installation, 'reps_by_location' => reps, 'intake_form_id' => site_form.id)

    expect(own.reload.is_active).to be false
    expect(site_form.reload.rotates?).to be true
    expect(Plays::NewWebsiteLead.installation_json(installation.reload)[:intake_form_id]).to eq(site_form.id)
  end

  it 'never makes someone from another company the form\'s notified user' do
    admin = make_user('admin', company_id: other_company.id)
    installation = install({ 'reps_by_location' => reps, 'intake_form_id' => 'new' }, admin)

    form = IntakeForm.find(installation.assets['intake_form_ids'].first)
    expect(form.notified_user_id).to be_nil
  end
end
