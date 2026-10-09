# frozen_string_literal: true

require 'rails_helper'

# Step 5 of the agreement: the signed purchase agreement locks the Deal Sheet
# version it was made from; an agreement whose sheet moved on cannot be sent;
# after signing, the deal changes by a change order the same people sign,
# which makes the draft version LIVE and locked, unpriced again.
RSpec.describe 'Deal Sheet lock and buyer change orders', type: :request do
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

  def create_agreement
    post "#{path}/agreement", headers: headers, params: { template_id: template.id, manager_id: manager.id }.to_json
    company.agreements.find(body['agreement']['id'])
  end

  it 'will not send an agreement whose Deal Sheet changed since it was made' do
    agreement = create_agreement
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: beam.id, quantity: 4 }.to_json
    post "/api/v1/agreements/#{agreement.id}/send_agreement", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['code']).to eq('deal_sheet_changed')
    expect(body['error']).to include('Make a new agreement')
  end

  it 'locks the sheet when signed, and changes it only by a change order the same people sign' do
    agreement = create_agreement
    live = deal.home_build
    post "/api/v1/agreements/#{agreement.id}/send_agreement", headers: headers
    expect(response).to have_http_status(:ok)

    sign_all(agreement)
    expect(agreement.reload.status).to eq('completed')
    expect(live.reload).to be_locked
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: beam.id }.to_json
    expect(response.status).to be >= 400 # a signed sheet does not change
    expect(live.lines.reload.map(&:catalog_option_id)).not_to include(beam.id)

    # The change goes on a draft copy.
    post "#{path}/versions", headers: headers, params: { copy_from_id: live.id, label: 'Add a beam' }.to_json
    draft = deal.home_builds.find_by(label: 'Add a beam')
    expect(draft).to have_attributes(live: false, status: 'draft')
    get "#{path}/buyer_change_order", headers: headers, params: { version_id: draft.id }
    expect(body['blocking']).to eq(['Nothing differs from the signed version yet'])

    post "#{path}/lines?version_id=#{draft.id}", headers: headers, params: { kind: 'option', option_id: beam.id, quantity: 12 }.to_json
    post "#{path}/make_live?version_id=#{draft.id}", headers: headers
    expect(response.status).to be >= 400 # it cannot simply replace the signed version

    get "#{path}/buyer_change_order", headers: headers, params: { version_id: draft.id }
    expect(body['blocking']).to be_empty
    expect(body['number']).to eq(1)
    expect(body['changes']['lines'].map { |l| [l['change'], l['description']] }).to eq([['add', 'Wood Beam On Ceiling - Per LF']])
    beam_retail = draft.lines.reload.find_by(catalog_option_id: beam.id).retail.to_f
    expect(body['changes']['totals']['difference']).to be >= beam_retail # plus any tax on it

    post "#{path}/buyer_change_order?version_id=#{draft.id}", headers: headers
    expect(response).to have_http_status(:created)
    co = company.agreements.find(body['agreement']['id'])
    expect(co).to have_attributes(status: 'draft', content_type: 'pdf_upload', parent_agreement_id: agreement.id)
    expect(co.agreement_signers.order(:id).map(&:name)).to eq(agreement.agreement_signers.order(:id).map(&:name))
    expect(co.field_placements.map { |p| p['signerIndex'] }.uniq).to contain_exactly(0, 1, 2, 3)
    text = PDF::Reader.new(StringIO.new(BuyerChangeOrderPdfGenerator.new(
      Agreements::BuyerChangeOrder.new(deal.reload, draft.reload, user: rep), number: 1, agreement_number: co.agreement_number,
      parent_number: agreement.agreement_number, signers: [{ label: 'Buyer 1', name: 'Pat Smith' }]
    ).generate)).pages.map(&:text).join("\n")
    expect(text).to include('Change Order No. 1', agreement.agreement_number, 'Wood Beam On Ceiling', 'Contract total with this change')
    expect(text).not_to include('$720.00') # dealer cost never prints

    get "#{path}/buyer_change_order", headers: headers, params: { version_id: draft.id }
    expect(body['blocking'].join).to include('still open')

    post "/api/v1/agreements/#{co.id}/send_agreement", headers: headers
    expect(response).to have_http_status(:ok)
    sign_all(co)
    expect(co.reload.status).to eq('completed')
    expect(deal.reload.home_build).to eq(draft)
    expect(draft.reload).to have_attributes(live: true, status: 'locked')
    expect(live.reload).to have_attributes(live: false, status: 'locked')
    expect(draft.reload.lines.find_by(catalog_option_id: beam.id).retail.to_f).to eq(beam_retail) # not repriced
  end

  it 'refuses a change order while the sheet is not signed' do
    post "#{path}/versions", headers: headers, params: { copy_from_id: deal.home_build.id, label: 'Other' }.to_json
    draft = deal.home_builds.find_by(label: 'Other')
    post "#{path}/buyer_change_order?version_id=#{draft.id}", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include('not signed yet')
  end

  it 'does not lock the sheet for other paperwork on the deal' do
    other = company.agreements.create!(title: 'Credit app', status: 'sent', deal: deal, content_type: 'rich_text', content: '<p>x</p>',
                                       metadata: { 'deal_sheet' => Agreement.deal_sheet_stamp(deal.home_build) })
    other.agreement_signers.create!(role: 'signer', name: 'Pat Smith', email: 'pat@example.com', signing_order: 1)
    sign_all(other)
    expect(other.reload.status).to eq('completed')
    expect(deal.home_build.reload).not_to be_locked
  end
end
