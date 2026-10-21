# frozen_string_literal: true

require 'rails_helper'

# An intake form can send new leads to one person or rotate them between reps.
# The rotation is a RoundRobinAssignmentList, so a play running on the form
# shares the same list and the same place in line.
RSpec.describe IntakeForm, 'lead rotation', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:other_company) { Company.create!(name: "Other-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  def make_user(label, company_id: company.id, status: 'active')
    User.create!(email: "#{label}-#{SecureRandom.hex(4)}@example.com", first_name: label.capitalize,
                 last_name: 'Rep', password: 'Pass1234!', company_id: company_id, role: 'sales_rep', status: status)
  end

  let!(:payton) { make_user('payton') }
  let!(:mike) { make_user('mike') }

  let(:schema) do
    [{ 'name' => 'first_name', 'type' => 'text', 'leadField' => 'first_name' },
     { 'name' => 'email', 'type' => 'email', 'leadField' => 'email' }]
  end

  def make_form(**attrs)
    IntakeForm.create!({ company_id: company.id, name: 'Website Contact', schema: schema, is_active: true,
                         auto_create_lead: true, auto_create_activity: true, notified_user_id: payton.id }.merge(attrs))
  end

  before { allow(CommunicationService).to receive(:send_email).and_return(nil) }

  def submit!(form)
    IntakeSubmission.create!(intake_form_id: form.id,
                             data: { 'first_name' => 'Tia', 'email' => "t-#{SecureRandom.hex(3)}@example.com" })
  end

  it 'saves the chosen reps as a rotation list, keeping only active reps at this dealership' do
    outsider = make_user('outsider', company_id: other_company.id)
    gone = make_user('gone', status: 'inactive')
    form = make_form(assignment_mode: 'round_robin', rotation_user_ids: [mike.id, outsider.id, gone.id, payton.id])

    list = form.reload.round_robin_list
    expect(list.company_id).to eq(company.id)
    expect(list.user_ids).to eq([mike.id, payton.id])
    expect(form.rotates?).to be true
    expect(form.as_json['rotationUserIds']).to eq([mike.id, payton.id])
  end

  it 'edits the same list in place, so anything sharing it keeps its place in line' do
    form = make_form(assignment_mode: 'round_robin', rotation_user_ids: [mike.id])
    list_id = form.round_robin_list_id

    form.update!(rotation_user_ids: [payton.id, mike.id])
    expect(form.reload.round_robin_list_id).to eq(list_id)
    expect(RoundRobinAssignmentList.find(list_id).user_ids).to eq([payton.id, mike.id])
  end

  it 'refuses a rotation with nobody in it' do
    form = IntakeForm.new(company_id: company.id, name: 'Empty', schema: schema, assignment_mode: 'round_robin', rotation_user_ids: [])
    expect(form).not_to be_valid
  end

  it 'refuses a notified user from another company' do
    outsider = make_user('outsider', company_id: other_company.id)
    expect { make_form(notified_user_id: outsider.id) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'gives each new lead the next rep and files the form task to that rep, not the notified user' do
    form = make_form(assignment_mode: 'round_robin', rotation_user_ids: [mike.id, payton.id])

    first = Lead.find(submit!(form).lead_id)
    second = Lead.find(submit!(form).lead_id)

    expect([first.owner_id, second.owner_id]).to eq([mike.id, payton.id])
    expect(LeadActivity.where(lead_id: first.id).pluck(:assigned_to_id).uniq).to eq([mike.id])
    expect(CommunicationService).to have_received(:send_email).with(hash_including(to: mike.email))
  end

  it 'falls back to the notified user when everyone in the rotation is inactive' do
    form = make_form(assignment_mode: 'round_robin', rotation_user_ids: [mike.id])
    mike.update!(status: 'inactive')

    expect(Lead.find(submit!(form).lead_id).owner_id).to eq(payton.id)
  end

  it 'still sends every lead to the one person when the form does not rotate' do
    form = make_form
    expect(Lead.find(submit!(form).lead_id).owner_id).to eq(payton.id)
  end
end
