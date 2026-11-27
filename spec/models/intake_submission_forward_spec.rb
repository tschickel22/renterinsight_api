# frozen_string_literal: true

require 'rails_helper'

# The James (production company 30) never signs in. Every website inquiry has to
# reach an outside inbox in full, and Reply has to reach the renter.
RSpec.describe IntakeSubmission, 'forwarding to outside inboxes', type: :model do
  let(:company) { Company.create!(name: "James-#{SecureRandom.hex(4)}", industry: 'property_management') }
  let(:inbox) { 'thejamesapartments@gmail.com' }

  let(:schema) do
    [
      { 'name' => 'first_name', 'label' => 'First name', 'type' => 'text', 'leadField' => 'first_name', 'order' => 1 },
      { 'name' => 'last_name', 'label' => 'Last name', 'type' => 'text', 'leadField' => 'last_name', 'order' => 2 },
      { 'name' => 'email', 'label' => 'Email', 'type' => 'email', 'leadField' => 'email', 'order' => 3 },
      { 'name' => 'phone', 'label' => 'Phone', 'type' => 'tel', 'leadField' => 'phone', 'order' => 4 },
      { 'name' => 'move_in', 'label' => 'When would you like to move in?', 'type' => 'text', 'order' => 5 },
      { 'name' => 'notes', 'label' => 'Notes', 'type' => 'textarea', 'order' => 6 }
    ]
  end

  def make_form(**attrs)
    IntakeForm.create!({
      company_id: company.id, name: 'Contact Us', schema: schema, is_active: true,
      auto_create_lead: true, auto_create_activity: true, forward_to_emails: [inbox]
    }.merge(attrs))
  end

  def submit!(form, **data)
    IntakeSubmission.create!(
      intake_form_id: form.id,
      referrer: 'https://www.jamesapts.com/contact',
      data: {
        'first_name' => 'Ana', 'last_name' => 'Ruiz', 'email' => 'ana.ruiz@gmail.test',
        'phone' => '(206) 555-0142', 'move_in' => 'January',
        'notes' => '<script>alert(1)</script> Is the studio still open?',
        'utm_source' => 'google', 'captcha_token' => 'xyz'
      }.merge(data.transform_keys(&:to_s))
    )
  end

  let(:sent) { [] }

  before do
    allow(CommunicationService).to receive(:send_email) { |**args| sent << args; nil }
  end

  def forwards = sent.select { |a| a[:metadata][:source] == 'intake_form_forward' }

  it 'forwards the full inquiry when the form notifies nobody' do
    submit!(make_form(notified_user_id: nil))

    expect(forwards.size).to eq(1)
    mail = forwards.first
    expect(mail[:to]).to eq(inbox)
    expect(mail[:reply_to]).to eq('ana.ruiz@gmail.test')
    expect(mail[:subject]).to eq('New inquiry from Ana Ruiz')
    expect(mail[:body]).to include('When would you like to move in?', 'January')
    expect(mail[:body]).to include('mailto:ana.ruiz@gmail.test', 'tel:2065550142')
    expect(mail[:body]).to include('https://www.jamesapts.com/contact')
    expect(mail[:communicable]).to be_a(IntakeForm)
  end

  it 'escapes what the visitor typed and leaves out internal keys and any CRM link' do
    submit!(make_form)
    body = forwards.first[:body]

    expect(body).not_to include('<script>')
    expect(body).to include('&lt;script&gt;')
    expect(body).not_to include('captcha', 'Utm source', 'View Lead', '/crm/leads')
  end

  it 'still forwards when the form creates no lead' do
    submit!(make_form(auto_create_lead: false))

    expect(forwards.size).to eq(1)
  end

  it 'calls a second inquiry from the same person a repeat' do
    form = make_form
    submit!(form)
    submit!(form, notes: 'Following up')

    expect(forwards.last[:subject]).to eq('Repeat inquiry from Ana Ruiz')
  end

  it 'skips an address the CRM already notifies' do
    rep = User.create!(email: inbox, first_name: 'Natalie', last_name: 'W', password: 'Pass1234!',
                       company_id: company.id, role: 'sales_rep')
    submit!(make_form(notified_user_id: rep.id))

    expect(forwards).to be_empty
    expect(sent.map { |a| a[:to] }).to eq([inbox])
  end

  it 'never fails the submission when the email cannot be sent' do
    allow(CommunicationService).to receive(:send_email).and_raise(StandardError, 'SES down')

    expect { submit!(make_form) }.not_to raise_error
    expect(IntakeSubmission.count).to eq(1)
  end

  it 'sends nothing extra when no outside inbox is set' do
    submit!(make_form(forward_to_emails: []))

    expect(forwards).to be_empty
  end
end

RSpec.describe IntakeForm, 'outside inboxes', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'property_management') }

  def form_with(list)
    IntakeForm.new(company_id: company.id, name: 'Contact', forward_to_emails: list,
                   schema: [{ 'name' => 'email', 'type' => 'email', 'leadField' => 'email' }])
  end

  it 'trims, lowercases, splits a pasted list and drops repeats' do
    form = form_with([' TheJamesApartments@Gmail.com, office@james.test', 'office@james.test', ''])
    expect(form).to be_valid
    expect(form.forward_to_emails).to eq(%w[thejamesapartments@gmail.com office@james.test])
  end

  it 'refuses something that is not an address' do
    expect(form_with(['natalie at gmail'])).not_to be_valid
  end

  it 'allows at most five' do
    expect(form_with((1..6).map { |i| "p#{i}@james.test" })).not_to be_valid
  end

  it 'hands the list to the builder in both key styles' do
    json = form_with(['a@james.test']).as_json
    expect(json['forward_to_emails']).to eq(['a@james.test'])
    expect(json['forwardToEmails']).to eq(['a@james.test'])
  end
end
