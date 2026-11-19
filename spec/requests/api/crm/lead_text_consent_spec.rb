# frozen_string_literal: true

require 'rails_helper'

# Staff recording that a lead agreed to texts about their inquiry (E105).
RSpec.describe 'PATCH /api/crm/leads/:id/text-consent', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:lead) do
    Lead.create!(company_id: company.id, first_name: 'Sam', last_name: 'K', email: 'sam@example.com', phone: '3035551234')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}" }
  end

  def notes
    Note.where(entity_type: 'lead', entity_id: lead.id.to_s).pluck(:content)
  end

  it 'records the consent, notes who and why, and returns it for the card' do
    patch "/api/crm/leads/#{lead.id}/text-consent", params: { consented: true, basis: 'Signed up at Biloxi show' }, headers: headers

    expect(response).to have_http_status(:ok)
    tc = JSON.parse(response.body)['textConsent']
    expect(tc).to include('consented' => true, 'recorded' => true, 'legacy' => false)
    expect(lead.reload.may_text_about_inquiry).to be(true)
    expect(notes.last).to include('Text consent recorded by Rita Rep', 'Basis: Signed up at Biloxi show')
  end

  it 'refuses a consent with no stated basis' do
    patch "/api/crm/leads/#{lead.id}/text-consent", params: { consented: true }, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(lead.reload.sms_inquiry_consent).to be(false)
  end

  it 'will not override a STOP' do
    CommunicationPreference.find_or_create_for(recipient: lead, channel: 'sms').opt_out!('STOP')
    patch "/api/crm/leads/#{lead.id}/text-consent", params: { consented: true, basis: 'Asked on the phone' }, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['error']).to include('STOP')
    expect(lead.reload.sms_inquiry_consent).to be(false)
  end

  it 'removes consent and notes it' do
    lead.update!(sms_inquiry_consent: true, sms_inquiry_consent_at: 1.day.ago)
    patch "/api/crm/leads/#{lead.id}/text-consent", params: { consented: false }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(lead.reload.sms_inquiry_consent).to be(false)
    expect(notes.last).to include('Text consent removed by Rita Rep')
  end

  it 'shows the consent on the lead' do
    lead.update!(sms_inquiry_consent: true)
    get "/api/crm/leads/#{lead.id}", headers: headers

    body = JSON.parse(response.body)
    consent = body['textConsent'] || body.dig('lead', 'textConsent')
    expect(consent).to include('consented' => true)
  end

  describe 'on the contact' do
    let(:contact) { Contact.create!(company_id: company.id, first_name: 'Sam', last_name: 'K', email: 'sam@example.com') }

    it 'carries staff consent, with who and why, to the contact page' do
      patch "/api/crm/leads/#{lead.id}/text-consent", params: { consented: true, basis: 'Agreed on a call' }, headers: headers
      expect(InquiryTextConsent.carry!(lead.reload, to: contact)).to be(true)

      get "/api/v1/contacts/#{contact.id}", headers: headers
      body = JSON.parse(response.body)
      tc = body['textConsent'] || body.dig('contact', 'textConsent') || body.dig('data', 'textConsent')
      expect(tc).to include('consented' => true, 'basis' => 'Agreed on a call', 'recordedByName' => 'Rita Rep', 'carriedFrom' => "Lead##{lead.id}")
    end

    it 'carries a lead marked without a record, and nothing for a lead without consent' do
      lead.update!(sms_inquiry_consent: true, sms_inquiry_consent_at: 2.days.ago)
      expect(InquiryTextConsent.carry!(lead, to: contact)).to be(true)
      expect(InquiryTextConsent.json(contact)).to include(consented: true, source: 'lead_record')

      other = Lead.create!(company_id: company.id, first_name: 'No', last_name: 'Consent', email: 'n@example.com')
      other_contact = Contact.create!(company_id: company.id, first_name: 'No', last_name: 'Consent', email: 'n@example.com')
      expect(InquiryTextConsent.carry!(other, to: other_contact)).to be(false)
      expect(InquiryTextConsent.json(other_contact)).to include(consented: false, recorded: false)
    end

    it 'never overwrites what the contact already holds' do
      CommunicationPreference.create!(recipient: contact, channel: 'sms', category: 'transactional', opted_in: false)
      lead.update!(sms_inquiry_consent: true)
      expect(InquiryTextConsent.carry!(lead, to: contact)).to be(false)
      expect(InquiryTextConsent.json(contact)[:consented]).to be(false)
    end
  end
end
