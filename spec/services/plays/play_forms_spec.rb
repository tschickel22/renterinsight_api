# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Play intake forms' do
  let(:company) { Company.create!(name: "Summit Park #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:location) { company.locations.find_by(is_default: true) }
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let(:answers) { { 'reps_by_location' => { location.id.to_s => [rep.id] } } }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Plays::LeadResponsePlay).to receive(:texting_ready?).and_return(false)
  end

  def install(play)
    play.new(company: company, user: rep, answers: answers).install!
  end

  def forms_of(installation)
    IntakeForm.where(company_id: company.id, id: Array(installation.assets['intake_form_ids']))
  end

  it 'gives a walk-in visit its own form, with a phone field a public form can draw' do
    installation = install(Plays::WalkInVisit)
    form = forms_of(installation).first

    expect(form.name).to eq('Walk-in Contact')
    phone = form.fields.find { |field| field['name'] == 'Phone' }
    # 'tel' was not a type any renderer drew: the field vanished, stayed
    # required, and the form silently refused to submit.
    expect(phone['type']).to eq('phone')
    expect(phone['required']).to be true
    expect(form.fields.map { |field| field['type'] }).not_to include('tel')
    expect(form.fields.map { |field| field['name'] }).to include('First Name', 'Last Name', 'Email', 'Phone', 'Text Me')
  end

  it 'creates the form when a play that is already on has none' do
    installation = install(Plays::WalkInVisit)
    forms_of(installation).destroy_all
    installation.update!(assets: installation.assets.merge('intake_form_ids' => []))

    Plays::WalkInVisit.new(company: company, user: rep, answers: answers, installation: installation.reload).customize!

    expect(forms_of(installation.reload).pluck(:name)).to eq(['Walk-in Contact'])
  end
end
