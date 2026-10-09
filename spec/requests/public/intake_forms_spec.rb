# frozen_string_literal: true

require 'rails_helper'

# The contact form on a published dealer site read its definition from the
# staff API, which a dealer's own hostname may not read cross-origin, so the
# form showed "Failed to fetch" on every live site.
RSpec.describe 'Public intake form', type: :request do
  let(:company) do
    Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing').tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(16))
    end
  end
  let!(:form) do
    IntakeForm.create!(company_id: company.id, name: 'Website Contact', description: 'Say hello',
                       schema: [], is_active: true, auto_create_lead: true, auto_create_activity: false,
                       hide_name: true)
  end

  def fetch(id: form.id, token: company.public_inventory_token, company_id: company.id, origin: 'https://easy-homesource-2.mydealertide.com')
    get "/public/intake_forms/#{id}", params: { token: token, company_id: company_id }, headers: { 'Origin' => origin }
  end

  it "serves the visitor's view of the form to a dealer's own hostname" do
    fetch

    expect(response).to have_http_status(:ok)
    expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
    body = JSON.parse(response.body)
    expect(body).to include('name' => 'Website Contact', 'publicId' => form.public_id, 'hideName' => true)
    # The builder's configuration stays out of it.
    expect(body).not_to have_key('notified_user_id')
    expect(body).not_to have_key('field_mappings')
  end

  it 'refuses a wrong token' do
    fetch(token: 'nope')
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses another company's form under this token" do
    other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
    theirs = IntakeForm.create!(company_id: other.id, name: 'Theirs', schema: [], is_active: true)

    fetch(id: theirs.id)
    expect(response).to have_http_status(:not_found)
  end

  it 'does not serve a form that is switched off' do
    form.update!(is_active: false)
    fetch
    expect(response).to have_http_status(:not_found)
  end
end
