# frozen_string_literal: true

require 'rails_helper'

# Questions buyers ask Quinn AI (E96): the dealer answers the ones it could
# not, and the answer becomes a FAQ it uses; DealerTide sees them all.
RSpec.describe 'Quinn AI questions', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'Ada', last_name: 'Admin', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let!(:unknown) { company.assistant_questions.create!(question: 'Do you deliver to Wyoming?', status: 'unanswered', topic: 'delivery') }
  let!(:known) { company.assistant_questions.create!(question: 'What are your hours?', status: 'answered', topic: 'hours') }

  it 'lists what Quinn could not answer, and an answer becomes a FAQ it uses' do
    get '/api/crm/assistant_questions', headers: headers
    body = JSON.parse(response.body)
    expect(body['items'].map { |q| q['id'] }).to eq([unknown.id])
    expect(body['counts']).to eq('needing_answer' => 1, 'all' => 2)

    post "/api/crm/assistant_questions/#{unknown.id}/answer", headers: headers,
         params: { answer: 'Yes, anywhere within 300 miles of Denver.' }.to_json
    expect(response).to have_http_status(:ok)
    expect(Assistant::Settings.for(company)['faqs']).to eq([{ 'q' => 'Do you deliver to Wyoming?', 'a' => 'Yes, anywhere within 300 miles of Denver.' }])

    lead = company.leads.create!(first_name: 'T', last_name: 'M', phone: '3035550144')
    conversation = Conversation.create!(company: company, conversable: lead, sender_number: '+17205550100', buyer_phone: lead.phone, started_at: Time.current)
    prompt = Assistant::Brain.new(conversation: conversation, settings: Assistant::Settings.for(company), history: []).system_prompt
    expect(prompt).to include('Q: Do you deliver to Wyoming?', 'A: Yes, anywhere within 300 miles of Denver.')

    get '/api/crm/assistant_questions', headers: headers
    expect(JSON.parse(response.body)['items']).to be_empty
  end

  it 'lets the dealer dismiss one' do
    post "/api/crm/assistant_questions/#{unknown.id}/dismiss", headers: headers
    expect(unknown.reload.status).to eq('dismissed')
  end

  it 'never shows another company the questions' do
    other = Company.create!(name: "O-#{SecureRandom.hex(3)}")
    u = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: 'O', last_name: 'X', password: 'Pass1234!',
                     company_id: other.id, role: 'company_admin', status: 'active')
    h = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: u.id, company_id: other.id)}" }
    post "/api/crm/assistant_questions/#{unknown.id}/dismiss", headers: h
    expect(response).to have_http_status(:not_found)
  end

  it 'keeps the cross-dealer list for platform admins' do
    get '/api/admin/assistant_questions', headers: headers
    expect(response.status).to be >= 400
  end
end
