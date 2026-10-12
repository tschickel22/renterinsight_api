# frozen_string_literal: true

require 'rails_helper'

# The buyers sign what the Deal Sheet says: while an agreement or change order
# is out for signature its version cannot change, and signing locks or applies
# only what was signed. Found in a review on 2026-10-11, each was a way for a
# signed deal to differ from what the buyers saw.
RSpec.describe 'Deal Sheet signing guards', type: :request do
  let(:packet) { JSON.parse(File.read(Rails.root.join('script/agreement_templates/fdhc_indiana_packet.json'))) }
  let(:company) { Company.create!(name: "Factory Direct #{SecureRandom.hex(3)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let!(:template) { company.agreement_templates.create!(name: 'FD Packet', status: 'active', template_type: 'upload', form_type: 'purchase_agreement', packet: packet) }
  let(:mfr) { Manufacturer.create!(name: 'Champion Home Builders', industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Bay Port') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32168', width_ft: 28, length_ft: 56) }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'construction', name: 'Construction', selection_type: 'multiple') }
  let!(:insulation) do
    CatalogOption.create!(group: group, manufacturer: mfr, key: 'construction--insulation', name: 'Upgrade Insulation', kind: 'upgrade', factory_code: 'INS38')
                 .tap { |o| CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 1295) }
  end
  let!(:beam) do
    CatalogOption.create!(group: group, manufacturer: mfr, key: 'construction--beam', name: 'Wood Beam On Ceiling - Per LF', kind: 'upgrade')
                 .tap { |o| CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 60) }
  end
  let(:rep) { User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let!(:manager) { User.create!(email: "mgr-#{SecureRandom.hex(4)}@example.com", first_name: 'Max', last_name: 'Manager', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:co_buyer) { company.contacts.create!(first_name: 'Sam', last_name: 'Smith', email: 'sam@example.com') }
  let(:deal) { company.deals.create!(name: 'Smith Bay Port', contact_id: buyer.id, co_applicant_contact_id: co_buyer.id, owner_id: rep.id) }
  let(:path) { "/api/v1/deals/#{deal.id}/home_build" }

  def body = JSON.parse(response.body)
  def sign_all(agreement) = agreement.agreement_signers.order(:id).each { |s| s.sign!(typed_signature: s.name, signature_method: 'typed') }

  before do
    allow(SealAgreementJob).to receive(:perform_now)
    allow(SealAgreementJob).to receive(:perform_later)
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645)
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    Truebuild::DealBuild.start(deal: deal, variant: variant).add_option(insulation.id)
  end

  def create_agreement(tpl = template)
    post "#{path}/agreement", headers: headers, params: { template_id: tpl.id, manager_id: manager.id }.to_json
    company.agreements.find(body['agreement']['id'])
  end

  def send_it(agreement)
    post "/api/v1/agreements/#{agreement.id}/send_agreement", headers: headers
    expect(response).to have_http_status(:ok)
  end

  it 'refuses sheet edits while the agreement is out, and locks exactly what was signed' do
    agreement = create_agreement
    live = deal.home_build
    send_it(agreement)
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: beam.id, quantity: 4 }.to_json
    expect(response).to have_http_status(:conflict)
    expect(body['error']).to include("#{agreement.agreement_number} is out for signature")

    sign_all(agreement)
    expect(live.reload).to be_locked
    expect(live.lines.map(&:catalog_option_id)).not_to include(beam.id)
    expect(agreement.reload.deal_sheet_status).to include(changed: false)
  end

  it 'refuses a new LIVE version while the agreement is out, leaving no orphan draft' do
    agreement = create_agreement
    send_it(agreement)
    expect do
      post "#{path}/versions", headers: headers, params: { copy_from_id: deal.home_build.id, label: 'Other', live: true }.to_json
    end.not_to change(DealHomeBuild, :count)
    expect(response).to have_http_status(:conflict)
  end

  it 'does not lock a sheet that changed behind the guard; it flags the agreement instead' do
    agreement = create_agreement
    live = deal.home_build
    send_it(agreement)
    live.lines.where(kind: 'option').update_all(quantity: 9) # a write that skipped every guard
    sign_all(agreement)
    expect(live.reload).not_to be_locked
    expect(agreement.reload.metadata['deal_sheet_not_applied']['reason']).to include('changed after the agreement was made')
  end

  context 'with a signed sheet and a change order out' do
    let!(:signed) { create_agreement.tap { |a| send_it(a); sign_all(a) } }
    let!(:draft) do
      post "#{path}/versions", headers: headers, params: { copy_from_id: deal.home_build.id, label: 'CO' }.to_json
      deal.home_builds.find_by(label: 'CO').tap do |d|
        post "#{path}/lines?version_id=#{d.id}", headers: headers, params: { kind: 'option', option_id: beam.id, quantity: 2 }.to_json
      end
    end
    let!(:change_order) do
      post "#{path}/buyer_change_order?version_id=#{draft.id}", headers: headers
      company.agreements.find(body['agreement']['id']).tap { |co| send_it(co) }
    end

    it 'refuses edits to the version the change order makes LIVE, and applies it as signed' do
      beam_line = draft.lines.reload.find_by(catalog_option_id: beam.id)
      patch "#{path}/lines/#{beam_line.id}?version_id=#{draft.id}", headers: headers, params: { quantity: 40 }.to_json
      expect(response).to have_http_status(:conflict)

      sign_all(change_order)
      expect(deal.reload.home_build).to eq(draft)
      expect(draft.reload).to be_locked
      expect(draft.lines.find_by(catalog_option_id: beam.id).quantity.to_i).to eq(2)
    end

    it 'refuses to unlock the signed sheet while a change order from it is out' do
      post "#{path}/unlock", headers: headers, params: { reason: 'Redo the deal' }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']).to include("#{change_order.agreement_number} is out for signature")
    end
  end

  it 'completes a paper-signed upload like an e-signed one, and refuses voided or stale ones' do
    allow(PrivateFiles).to receive(:upload).and_return({ ref: 'agreements/x/signed.pdf' })
    upload = ->(a) do
      file = Rack::Test::UploadedFile.new(StringIO.new('%PDF-1.4 fake'), 'application/pdf', original_filename: 'signed.pdf')
      post "/api/v1/agreements/#{a.id}/upload_signed_document", headers: headers.except('Content-Type'), params: { document: file }
    end

    stale = create_agreement
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: beam.id, quantity: 4 }.to_json
    upload.call(stale)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(stale.reload.status).to eq('draft')

    voided = create_agreement
    voided.void!(rep, 'mistake')
    upload.call(voided)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(voided.reload.status).to eq('voided')

    good = create_agreement
    upload.call(good)
    expect(response).to have_http_status(:ok)
    expect(good.reload).to have_attributes(status: 'completed')
    expect(good.completed_at).to be_present
    expect(deal.home_build.reload).to be_locked
  end

  it 'refuses Products changes once the sheet is signed' do
    agreement = create_agreement
    send_it(agreement)
    sign_all(agreement)
    home = deal.deal_products.reload.find { |dp| dp.notes.to_s.include?('deal_sheet:home') }

    post "/api/crm/deals/#{deal.id}/products", headers: headers,
                                               params: { product: { product_name: 'Extended warranty', quantity: 1, unit_price: 5000 } }.to_json
    expect(response).to have_http_status(:conflict)
    delete "/api/crm/deals/#{deal.id}/products/#{home.id}", headers: headers
    expect(response).to have_http_status(:conflict)
    expect(deal.deal_products.find_by(id: home.id)).to be_present

    get "/api/crm/deals/#{deal.id}/products", headers: headers
    expect(body['deal_sheet']['locked_reason']).to include('locked by a signed agreement')
  end

  it 'keeps the contract details fixed once signed, but lets the unit identity be filled in' do
    agreement = create_agreement
    send_it(agreement)
    sign_all(agreement)

    patch "/api/v1/deals/#{deal.id}/sale_details", headers: headers, params: { contingency: 'financing' }.to_json
    expect(response).to have_http_status(:conflict)
    patch "/api/v1/deals/#{deal.id}/sale_details", headers: headers, params: { hud_labels: 'IND123456', model_year: '2026' }.to_json
    expect(response).to have_http_status(:ok)
  end

  it "refuses another company's deal or contact on an agreement" do
    other_co = Company.create!(name: "Rival #{SecureRandom.hex(3)}")
    other_contact = other_co.contacts.create!(first_name: 'Secret', last_name: 'Buyer', email: 's@example.com')
    other_deal = other_co.deals.create!(name: 'Rival Secret Deal', contact_id: other_contact.id)
    post '/api/v1/agreements', headers: headers,
                               params: { agreement: { title: 'x', content_type: 'rich_text', content: '<p>x</p>',
                                                      deal_id: other_deal.id, contact_id: other_contact.id } }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).not_to include('Rival Secret Deal')
  end

  it 'never lets a client write the Deal Sheet stamp' do
    agreement = create_agreement
    stamp = agreement.metadata['deal_sheet']
    patch "/api/v1/agreements/#{agreement.id}", headers: headers,
                                                params: { agreement: { metadata: { 'deal_sheet' => nil, 'note' => 'kept' } } }.to_json
    expect(agreement.reload.metadata['deal_sheet']).to eq(stamp)
    expect(agreement.metadata['note']).to eq('kept')
  end

  it 'refuses a package whose signer has no person, rather than shifting the signers' do
    bare = company.agreement_templates.create!(name: 'Bare', status: 'active', template_type: 'upload', form_type: 'purchase_agreement',
                                               packet: packet.except('signers'))
    template.update_columns(is_deleted: true)
    get "#{path}/agreement", headers: headers
    expect(body['check']['blocking']).to include('Choose the manager who accepts the agreement')
    post "#{path}/agreement", headers: headers, params: { template_id: bare.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "refuses a package or manager that is not on the dialog's lists" do
    other = Company.create!(name: "Rival #{SecureRandom.hex(3)}")
    foreign = other.agreement_templates.create!(name: 'Theirs', status: 'active', template_type: 'upload', form_type: 'purchase_agreement', packet: packet)
    post "#{path}/agreement", headers: headers, params: { template_id: foreign.id, manager_id: manager.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)

    manager.update_columns(status: 'inactive')
    post "#{path}/agreement", headers: headers, params: { template_id: template.id, manager_id: manager.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "shows a move in the home's price on the change order" do
    agreement = create_agreement
    send_it(agreement)
    sign_all(agreement)
    CatalogVariantPrice.find_by(price_book: book, variant: variant).update!(net_base_price: 59_645)
    post "#{path}/versions", headers: headers, params: { copy_from_id: deal.home_build.id, label: 'CO' }.to_json
    draft = deal.home_builds.find_by(label: 'CO')
    post "#{path}/lines?version_id=#{draft.id}", headers: headers, params: { kind: 'option', option_id: beam.id, quantity: 1 }.to_json
    get "#{path}/buyer_change_order", headers: headers, params: { version_id: draft.id }
    changes = body['changes']['lines'].map { |l| [l['change'], l['description']] }
    expect(changes).to include(['add', 'Wood Beam On Ceiling - Per LF'])
    expect(changes.map(&:first)).to include('price')
  end
end
