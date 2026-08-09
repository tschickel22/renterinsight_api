# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public::Concierge', type: :request do
  let(:company) do
    Company.create!(name: 'Summit Park Homes', phone: '555-0100', address_line1: '100 Lot Road',
                    city: 'Denver', state: 'CO',
                    public_inventory_token: SecureRandom.hex(16))
  end
  let(:location) { company.locations.create!(name: 'Showroom') }
  let!(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Summit',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'published')
  end
  let!(:form) { Websites::DefaultLeadForm.ensure_for(company) }
  let(:token) { company.public_inventory_token }

  before do
    allow_any_instance_of(ModuleAccessService).to receive(:module_enabled?).and_return(true)
  end

  def json
    JSON.parse(response.body)
  end

  describe 'POST /concierge/:token' do
    it 'tells the widget it can take details in the chat' do
      post "/concierge/#{token}", params: { message: 'hello' }.to_json,
                                  headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:ok)
      expect(json['lead_capture']).to include('enabled' => true, 'form_path' => '/contact')
      expect(json['lead_capture']['consent_text']).to include('Reply STOP to opt out')
    end

    it 'offers to keep a contact request in the chat rather than opening a form' do
      post "/concierge/#{token}", params: { message: 'hello' }.to_json,
                                  headers: { 'Content-Type' => 'application/json' }

      expect(json['quick_actions']).to include(hash_including('type' => 'capture', 'intent' => 'contact'))
    end

    it 'sends the form instead when the dealer made a CAPTCHA mandatory' do
      form.update!(captcha_required: true)

      post "/concierge/#{token}", params: { message: 'hello' }.to_json,
                                  headers: { 'Content-Type' => 'application/json' }

      expect(json['lead_capture']['enabled']).to be(false)
      expect(json['quick_actions']).to include(hash_including('type' => 'form', 'label' => 'Contact us'))
    end

    # Prefill is what makes it fair to ask for a name before showing a calendar.
    it 'prefills the dealer scheduler with what the visitor has given' do
      allow(Websites::BookingUrl).to receive(:resolve).and_return('https://calendly.com/summit/showing')

      post "/concierge/#{token}",
           params: { message: 'hello', visitor: { name: 'Jane Doe', email: 'jane@example.com' } }.to_json,
           headers: { 'Content-Type' => 'application/json' }

      meeting = json['quick_actions'].find { |a| a['type'] == 'link' }
      expect(meeting['url']).to include('name=Jane+Doe').and include('email=jane%40example.com')
    end

    it 'is a 404 for a token that belongs to nobody' do
      post '/concierge/not-a-real-token', params: { message: 'hello' }.to_json,
                                          headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /concierge/:token/lead' do
    def file(params)
      post "/concierge/#{token}/lead", params: params.to_json,
                                       headers: { 'Content-Type' => 'application/json' }
    end

    it 'creates the lead and says so' do
      expect { file(visitor: { name: 'Jane Doe', email: 'jane@example.com' }, intent: 'callback') }
        .to change(Lead, :count).by(1)

      expect(json['status']).to eq('created')
      expect(Lead.last).to have_attributes(first_name: 'Jane', email: 'jane@example.com')
    end

    it 'carries the conversation into the lead, so a salesperson has the context' do
      file(visitor: { name: 'Jane Doe', email: 'jane@example.com' },
           intent: 'callback',
           history: [{ role: 'user', content: '3 bed under 90k' }])

      expect(IntakeSubmission.order(:id).last.data['message']).to include('3 bed under 90k')
    end

    # The exposure here is the dealer's, and nothing else in the product asks
    # for this consent.
    it 'refuses to keep a phone number that was never consented to' do
      file(visitor: { name: 'Jane Doe', email: 'jane@example.com', phone: '555-1234' }, consented: false)

      expect(Lead.last.phone).to be_blank
    end

    it 'keeps it when the visitor agreed' do
      file(visitor: { name: 'Jane Doe', phone: '555-1234' }, consented: true)

      expect(Lead.last.phone).to eq('555-1234')
    end

    it 'asks for the form when it cannot satisfy the dealer' do
      form.update!(captcha_required: true)

      expect { file(visitor: { name: 'Jane Doe', email: 'jane@example.com' }) }.not_to change(Lead, :count)
      expect(json).to include('status' => 'form_required', 'form_path' => '/contact')
    end

    it 'says nothing was filed when it has too little to go on' do
      expect { file(visitor: { name: 'Jane Doe' }) }.not_to change(Lead, :count)
      expect(json['status']).to eq('incomplete')
    end

    # A demo runs on a prospect's own data to show them what it would look like.
    # Writing a real lead from one puts a stranger in a dealer's CRM.
    it 'never writes a lead from a shared demo' do
      profile = SiteContentProfile.create!(company: company, source_url: 'https://dealer.com',
                                           status: 'ready', source_kind: 'url',
                                           preview_token: SecureRandom.urlsafe_base64(24))

      expect do
        file(visitor: { name: 'Jane Doe', email: 'jane@example.com' }, demo_token: profile.preview_token)
      end.not_to change(Lead, :count)

      expect(json['status']).to eq('demo')
    end
  end
end
