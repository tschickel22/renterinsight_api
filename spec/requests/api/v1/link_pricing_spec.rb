# frozen_string_literal: true

require 'rails_helper'

# E68 step 6: the installer's rate card for a dealer, prices agreed before the
# work starts, change orders the dealer approves, and a bill that is exactly
# what was agreed.
RSpec.describe 'Linked installer pricing', type: :request do
  include ActiveJob::TestHelper

  let(:dealer_co) { create(:company, name: 'Summit Homes') }
  let(:installer_co) { create(:company, name: 'Summit Install') }
  let(:stranger_co) { create(:company, name: 'Someone Else') }

  def admin(company, email)
    User.create!(email: email, first_name: 'A', last_name: 'B', password: 'Pass1234!', company_id: company.id, role: 'company_admin', status: 'active')
  end

  let(:dealer) { admin(dealer_co, 'pat@summit.example') }
  let(:boss) { admin(installer_co, 'boss@install.example') }
  let(:stranger) { admin(stranger_co, 'x@else.example') }
  let(:vendor) { Contractor.create!(company: dealer_co, name: 'Summit Install (vendor)', email: 'boss@install.example', status: 'active') }
  let!(:location) { installer_co.locations.first || installer_co.locations.create!(name: 'Yard', active: true) }
  # Inviting needs the Linked Installers add-on, and the invited email must
  # already be an admin here.
  let!(:linked_addon) { TenantModuleOverride.create!(company: dealer_co, module_key: 'management.linked_companies', is_enabled: true) }
  before { boss }

  let(:project) do
    dealer_co.projects.create!(name: 'Diaz home', status: 'active', owner: dealer, customer_name: 'Maria Diaz',
                               delivery_city: 'Golden', delivery_state: 'CO')
  end
  let!(:set_phase) { project.project_phases.create!(company: dealer_co, name: 'Set', position: 0, status: 'not_started') }
  let!(:finish_phase) { project.project_phases.create!(company: dealer_co, name: 'Finish', position: 1, status: 'not_started') }

  def h(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}", 'Content-Type' => 'application/json' }
  def body = JSON.parse(response.body)

  let(:link) do
    post '/api/v1/company_links', headers: h(dealer), params: { vendor_id: vendor.id, email: boss.email }.to_json
    id = body.dig('company_link', 'id')
    post "/api/v1/company_links/#{id}/accept", headers: h(boss), params: { agree: true }.to_json
    CompanyLink.find(id)
  end

  def card!(items)
    post "/api/v1/company_links/#{link.id}/rate_cards", headers: h(boss), params: { items: items }.to_json
    expect(response).to have_http_status(:created), response.body
    LinkRateCard.find(body.dig('rate_card', 'id'))
  end

  let(:card_items) do
    [{ name: 'Double section set and finish', kind: 'base', unit: 'job', price: '4200' },
     { name: 'Skirting', kind: 'addon', unit: 'foot', price: '12.50' }]
  end

  def approved_card!
    card = card!(card_items)
    post "/api/v1/link_rate_cards/#{card.id}/approve", headers: h(dealer)
    expect(response).to have_http_status(:ok), response.body
    card.reload
  end

  def send!(params)
    post "/api/v1/projects/#{project.id}/project_links", headers: h(dealer),
         params: { company_link_id: link.id, project_phase_ids: [set_phase.id, finish_phase.id] }.merge(params).to_json
    expect(response).to have_http_status(:created), response.body
    ProjectLink.find(body.dig('project_link', 'id'))
  end

  def installer_phase(pl, dealer_phase)
    pl.link_phases.find_by(dealer_phase_id: dealer_phase.id).installer_phase
  end

  def start(pl, dealer_phase)
    ip = installer_phase(pl, dealer_phase)
    post "/api/v1/projects/#{ip.project_id}/set_phase_status", headers: h(boss), params: { phase_id: ip.id, status: 'in_progress' }.to_json
  end

  # E68 test 6.3: the tester set the link up as a platform admin working
  # inside the dealer, so the rate card went to the dealer's admins only.
  it 'also tells a platform admin who set the link up from inside the dealer' do
    support = User.create!(email: 'support@platform.example', first_name: 'S', last_name: 'P', password: 'Pass1234!',
                           company_id: stranger_co.id, role: 'platform_admin', status: 'active')
    link.update_columns(invited_by_id: support.id)

    card = card!(card_items)
    expect(Notification.where(recipient: support, notifiable: card)).to exist
    expect(Notification.where(recipient: dealer, notifiable: card)).to exist
    expect(Notification.where(recipient: stranger, notifiable: card)).not_to exist
  end

  it 'sends a rate card the dealer approves once, and keeps it in force until a new one is approved' do
    first = approved_card!
    expect(first).to be_approved
    expect(Notification.where(recipient: boss, notifiable: first).last.title).to include('approved your rate card')

    second = card!([{ name: 'Double section set and finish', kind: 'base', unit: 'job', price: '4400' }])
    expect(link.current_rate_card).to eq(first)
    expect(link.pending_rate_card).to eq(second)
    expect(Notification.where(recipient: dealer, notifiable: second)).to exist

    get '/api/v1/company_links', headers: h(dealer)
    row = body['as_dealer'].first
    expect(row.dig('rate_card', 'version')).to eq(1)
    expect(row.dig('pending_rate_card', 'items', 0, 'price')).to eq(4400.0)

    post "/api/v1/link_rate_cards/#{second.id}/approve", headers: h(boss)
    expect(response).to have_http_status(:unprocessable_entity) # the installer can't approve its own prices
    post "/api/v1/link_rate_cards/#{second.id}/approve", headers: h(stranger)
    expect(response).to have_http_status(:not_found)
    post "/api/v1/link_rate_cards/#{second.id}/approve", headers: h(dealer)
    expect(first.reload.status).to eq('superseded')
    expect(link.current_rate_card).to eq(second)
    expect { first.update!(items: [{ name: 'X', price: '1' }]) }.to raise_error(ActiveRecord::RecordNotSaved)

    post "/api/v1/company_links/#{link.id}/rate_cards", headers: h(boss), params: { items: [{ name: 'No price' }] }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'prices a job from the card at hand-off and bills exactly that, against the committed line' do
    card = approved_card!
    keys = card.items.map { |i| i['key'] }
    pl = send!(price_mode: 'card', card_lines: [{ item_key: keys[0], qty: 1 }, { item_key: keys[1], qty: 120 }])
    expect(pl.fee_amount).to eq(5700) # 4200 + 120 ft at 12.50
    expect(pl.price_source).to eq('card')
    expect(pl.dealer_cost_item).to have_attributes(amount: 5700, status: 'pending')

    post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss)
    expect(response).to have_http_status(:ok), response.body
    start(pl.reload, set_phase)
    expect(response).to have_http_status(:ok), response.body # agreed at hand-off, nothing to wait for

    post "/api/v1/project_links/#{pl.id}/bill", headers: h(boss), params: { amount: '6000' }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include('$5,700.00')

    post "/api/v1/project_links/#{pl.id}/bill", headers: h(boss), params: {}.to_json
    expect(response).to have_http_status(:ok), response.body
    bill = pl.reload.dealer_bill
    expect(bill.total_amount).to eq(5700)
    expect(pl.dealer_cost_item.reload.bill_id).to eq(bill.id)
    expect(project.project_cost_items.not_deleted.sum(:amount)).to eq(5700) # counted once
  end

  it 'holds a quoted job until the dealer approves the price, then makes it committed cost' do
    pl = send!(price_mode: 'quote')
    expect(pl.fee_amount).to be_nil
    expect(pl.dealer_cost_item).to be_nil

    post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss)
    expect(response).to have_http_status(:unprocessable_entity) # a quote job needs the price
    post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss),
         params: { price_lines: [{ name: 'Set and finish', qty: 1, price: '3900' }, { name: 'Crane', qty: 1, price: '600' }] }.to_json
    expect(response).to have_http_status(:ok), response.body
    request = pl.link_changes.last
    expect(request).to have_attributes(kind: 'price', status: 'pending', amount: 4500)
    expect(Notification.where(recipient: dealer, notifiable: request).last.title).to include('priced a job at $4,500.00')

    start(pl.reload, set_phase)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include("can't start until Summit Homes approves the price")
    ip = installer_phase(pl, set_phase)
    task = ip.project_phase_tasks.create!(company_id: installer_co.id, name: 'Level', position: 0)
    post "/api/v1/projects/#{ip.project_id}/toggle_task", headers: h(boss), params: { phase_id: ip.id, task_id: task.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(task.reload.status).not_to eq('completed')
    post "/api/v1/project_links/#{pl.id}/bill", headers: h(boss), params: {}.to_json
    expect(response).to have_http_status(:unprocessable_entity)

    post "/api/v1/project_link_changes/#{request.id}/approve", headers: h(boss)
    expect(response).to have_http_status(:unprocessable_entity) # only the dealer approves
    post "/api/v1/project_link_changes/#{request.id}/approve", headers: h(dealer)
    expect(response).to have_http_status(:ok), response.body
    pl.reload
    expect(pl.fee_amount).to eq(4500)
    expect(pl.dealer_cost_item).to have_attributes(amount: 4500, status: 'pending')
    expect(pl.installer_project.budget_amount).to eq(4500)

    start(pl, set_phase)
    expect(response).to have_http_status(:ok), response.body
  end

  it 'holds only the phase a change order names, and bills the price plus approved change orders' do
    pl = send!(fee: '4000')
    expect(pl.price_source).to eq('dealer')
    post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss)

    post "/api/v1/project_links/#{pl.id}/changes", headers: h(boss),
         params: { kind: 'change', description: 'Extra steps', dealer_phase_id: finish_phase.id,
                   lines: [{ name: 'Steps', qty: 2, price: '250' }] }.to_json
    expect(response).to have_http_status(:created), response.body
    co = ProjectLinkChange.find(body.dig('change', 'id'))
    expect(co).to have_attributes(number: 1, amount: 500)

    start(pl.reload, set_phase)
    expect(response).to have_http_status(:ok), response.body
    start(pl, finish_phase)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include('change order 1')

    post "/api/v1/project_links/#{pl.id}/bill", headers: h(boss), params: {}.to_json
    expect(body['error']).to include("hasn't decided")

    post "/api/v1/project_link_changes/#{co.id}/approve", headers: h(dealer)
    expect(co.reload.dealer_cost_item).to have_attributes(amount: 500, project_phase_id: finish_phase.id, status: 'pending')

    post "/api/v1/project_links/#{pl.id}/changes", headers: h(boss),
         params: { kind: 'change', description: 'Gutters', lines: [{ name: 'Gutters', qty: 1, price: '300' }] }.to_json
    declined = ProjectLinkChange.find(body.dig('change', 'id'))
    post "/api/v1/project_link_changes/#{declined.id}/decline", headers: h(dealer), params: { reason: 'Not needed' }.to_json
    expect(declined.reload.status).to eq('declined')

    get "/api/v1/projects/#{project.id}/project_links", headers: h(dealer)
    row = body['project_links'].first
    expect(row['approved_total']).to eq(4500.0)
    expect(row['changes'].map { |c| c['status'] }).to eq(%w[declined approved])

    # Both sides see the change orders on Bids & Quotes (E87 retest).
    get '/api/v1/bids_board', headers: h(dealer)
    orders = body['outgoing'].select { |r| r['source'] == 'change_order' }.to_h { |r| [r['title'], r['stage']] }
    expect(orders).to eq('Change order 1: Finish' => 'awarded', 'Change order 2: Set and Finish' => 'declined')
    get '/api/v1/bids_board', headers: h(boss)
    expect(body['incoming'].select { |r| r['source'] == 'change_order' }.map { |r| r['stage'] }).to match_array(%w[won not_awarded])

    post "/api/v1/project_links/#{pl.id}/bill", headers: h(boss), params: {}.to_json
    expect(response).to have_http_status(:ok), response.body
    pl.reload
    expect(pl.dealer_bill.total_amount).to eq(4500)
    expect(pl.installer_invoice.invoice_items.order(:position).pluck(:rate)).to eq([4000, 500])
    expect(project.project_cost_items.not_deleted.where(bill_id: pl.dealer_bill_id).sum(:amount)).to eq(4500)
    expect(project.project_cost_items.not_deleted.sum(:amount)).to eq(4500)
  end

  it 'withdraws waiting requests and removes committed lines when the dealer takes the job back' do
    pl = send!(fee: '4000')
    post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss)
    post "/api/v1/project_links/#{pl.id}/changes", headers: h(boss),
         params: { description: 'Steps', lines: [{ name: 'Steps', qty: 1, price: '250' }] }.to_json
    waiting = ProjectLinkChange.find(body.dig('change', 'id'))
    post "/api/v1/project_links/#{pl.id}/changes", headers: h(boss),
         params: { description: 'Deck', lines: [{ name: 'Deck', qty: 1, price: '900' }] }.to_json
    approved = ProjectLinkChange.find(body.dig('change', 'id'))
    post "/api/v1/project_link_changes/#{approved.id}/approve", headers: h(dealer)
    line_id = approved.reload.dealer_cost_item_id

    post "/api/v1/project_links/#{pl.id}/cancel", headers: h(dealer)
    expect(response).to have_http_status(:ok), response.body
    expect(waiting.reload.status).to eq('withdrawn')
    expect(ProjectCostItem.exists?(line_id)).to be(false)
    expect(project.project_cost_items.not_deleted.count).to eq(0)
  end
end
