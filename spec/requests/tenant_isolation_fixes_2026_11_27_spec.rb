# frozen_string_literal: true

require 'rails_helper'

# Five holes found writing the E118 notes (MODULE_BUGS_FOUND_2026-11-27.md):
# tags, portal logins, private reports, intake submissions, portal deletes.
RSpec.describe 'Tenant isolation fixes 2026-11-27', type: :request do
  let(:company) { Company.create!(name: "Mine-#{SecureRandom.hex(4)}") }
  let(:other)   { Company.create!(name: "Other-#{SecureRandom.hex(4)}") }

  def user_in(co, role: 'company_admin')
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: co.id, role: role)
  end

  def headers_for(user) = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: user.company_id)}" }

  let(:me) { user_in(company) }
  let(:headers) { headers_for(me) }

  describe 'tags' do
    let!(:their_lead) { other.leads.create!(first_name: 'Their', last_name: 'Lead', email: "t-#{SecureRandom.hex(3)}@example.com") }
    let!(:my_lead)    { company.leads.create!(first_name: 'My', last_name: 'Lead', email: "m-#{SecureRandom.hex(3)}@example.com") }
    let!(:their_tag)  { other.tags.create!(name: 'Theirs', color: '#000000') }
    let!(:my_tag)     { company.tags.create!(name: 'Mine', color: '#000000') }
    let!(:global_tag) { Tag.create!(name: "Global-#{SecureRandom.hex(3)}", color: '#000000') }

    it "will not put a tag on another dealer's lead" do
      post '/api/crm/tags/assign', params: { lead_id: their_lead.id, tag_id: my_tag.id }, headers: headers
      expect(response).to have_http_status(:not_found)
      expect(TagAssignment.where(entity_type: 'Lead', entity_id: their_lead.id)).to be_empty
    end

    it "will not use another dealer's tag" do
      post '/api/crm/tags/assign', params: { lead_id: my_lead.id, tag_id: their_tag.id }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it 'still tags my own lead, with a global tag too, and records the company' do
      post '/api/crm/tags/assign', params: { lead_id: my_lead.id, tag_id: global_tag.id }, headers: headers
      expect(response).to have_http_status(:created)
      expect(TagAssignment.find_by(entity_id: my_lead.id, tag_id: global_tag.id).company_id).to eq(company.id)
    end

    it "will not read another dealer's lead tags" do
      TagAssignment.create!(tag: their_tag, entity_type: 'Lead', entity_id: their_lead.id, company_id: other.id, assigned_at: Time.current)
      get "/api/crm/tags/entity/Lead/#{their_lead.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "will not remove another dealer's tag assignment by id" do
      a = TagAssignment.create!(tag: their_tag, entity_type: 'Lead', entity_id: their_lead.id, company_id: other.id, assigned_at: Time.current)
      delete "/api/crm/tags/assignments/#{a.id}", headers: headers
      expect(TagAssignment.exists?(a.id)).to be(true)
    end

    it 'creates a tag by name in my company, not as a global one' do
      post '/api/crm/tags/assign', params: { lead_id: my_lead.id, name: 'Brand new' }, headers: headers
      expect(company.tags.find_by(name: 'Brand new')).to be_present
    end

    it 'will not edit or delete a global tag' do
      patch "/api/crm/tags/#{global_tag.id}", params: { tag: { name: 'Hijacked' } }, headers: headers
      expect(response).to have_http_status(:not_found)
      delete "/api/crm/tags/#{global_tag.id}", headers: headers
      expect(Tag.exists?(global_tag.id)).to be(true)
    end
  end

  describe 'portal login lookup' do
    it "does not match a buyer's login at another dealer" do
      c = other.contacts.create!(first_name: 'B', last_name: 'B', email: 'buyer@example.com')
      BuyerPortalAccess.create!(buyer: c, company: other, email: 'buyer@example.com', password: 'Password123!',
                                password_confirmation: 'Password123!', portal_enabled: true)
      expect(PortalPushService.send(:access_for_email, company.id, 'buyer@example.com')).to be_nil
      expect(PortalPushService.send(:access_for_email, other.id, 'buyer@example.com')).to be_present
    end
  end

  describe 'private reports' do
    let(:owner) { user_in(company, role: 'staff') }
    let(:colleague) { user_in(company, role: 'staff') }
    let!(:report) { company.reports.create!(name: 'Mine only', module_key: 'leads', user_id: owner.id, visibility: 'private', config: {}) }

    it "won't open for a colleague by id" do
      get "/api/v1/reports/#{report.id}", headers: headers_for(colleague)
      expect(response).to have_http_status(:not_found)
      get "/api/v1/reports/#{report.id}/export", headers: headers_for(colleague)
      expect(response).to have_http_status(:not_found)
    end

    it 'opens for its owner, a person it is shared with, and an admin' do
      get "/api/v1/reports/#{report.id}", headers: headers_for(owner)
      expect(response).to have_http_status(:ok)
      report.update!(shared_user_ids: [colleague.id])
      get "/api/v1/reports/#{report.id}", headers: headers_for(colleague)
      expect(response).to have_http_status(:ok)
      get "/api/v1/reports/#{report.id}", headers: headers
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'intake submissions' do
    let!(:their_form) { other.intake_forms.create!(name: 'Their form', is_active: true) }
    let!(:my_form) { company.intake_forms.create!(name: 'My form', is_active: true) }

    it 'need a sign-in' do
      post '/api/crm/intake/submissions/bulk', params: [{ formId: my_form.id, first_name: 'A', email: 'a@example.com' }].to_json,
                                               headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response).to have_http_status(:unauthorized)
    end

    it "won't submit to another dealer's form" do
      expect {
        post '/api/crm/intake/submissions', params: { intake_form_id: their_form.id, first_name: 'A' }, headers: headers
      }.not_to change(IntakeSubmission, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "ignores a location that is not the form's company's" do
      theirs = other.locations.create!(name: 'Their lot', timezone: 'UTC')
      post '/api/crm/intake/submissions', params: { intake_form_id: my_form.id, payload: { first_name: 'Al', last_name: 'B',
                                                    email: "al-#{SecureRandom.hex(3)}@example.com", location_id: theirs.id } }, headers: headers
      lead = IntakeSubmission.order(:id).last&.lead
      expect(lead).to be_present
      expect(lead.location_id).not_to eq(theirs.id)
    end
  end

  describe 'portal documents' do
    let(:contact) { company.contacts.create!(first_name: 'P', last_name: 'B', email: "p-#{SecureRandom.hex(3)}@example.com") }
    let(:access) do
      BuyerPortalAccess.create!(buyer: contact, company: company, email: contact.email, password: 'Password123!',
                                password_confirmation: 'Password123!', portal_enabled: true)
    end
    let(:portal_headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode({ buyer_portal_access_id: access.id }, 1.hour.from_now)}" } }

    def doc(by)
      d = PortalDocument.new(owner: contact, uploaded_by: by, category: 'other', document_name: 'x.pdf')
      d.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'x.pdf', content_type: 'application/pdf')
      d.save!
      d
    end

    it "won't let the buyer delete a file the dealer shared" do
      d = doc('admin')
      delete "/api/portal/documents/#{d.id}", headers: portal_headers
      expect(response).to have_http_status(:forbidden)
      expect(PortalDocument.exists?(d.id)).to be(true)
    end

    it 'lets the buyer delete their own upload' do
      d = doc('buyer')
      delete "/api/portal/documents/#{d.id}", headers: portal_headers
      expect(response).to have_http_status(:ok)
    end
  end
end
