# frozen_string_literal: true

require 'rails_helper'

# Staging demo accounts go stale because every Workqueue queue is a time
# window. DemoRefresh rebuilds a cast of demo buyers around "now", owned by
# whoever pressed the button, and must never touch the rest of the company.
RSpec.describe DemoRefresh, type: :service do
  let(:company) { Company.create!(name: "Demo-#{SecureRandom.hex(4)}", is_demo: true) }
  let(:user) do
    User.create!(email: "dr-#{SecureRandom.hex(4)}@example.com", first_name: 'Tom', last_name: 'Admin',
                 password: 'Pass1234!', company_id: company.id, role: 'admin')
  end
  let(:other_rep) do
    User.create!(email: "dr-#{SecureRandom.hex(4)}@example.com", first_name: 'Ona', last_name: 'Other',
                 password: 'Pass1234!', company_id: company.id)
  end

  before do
    stub_const('ENV', ENV.to_h.merge('DEMO_REFRESH_COMPANY_IDS' => company.id.to_s))

    4.times do |i|
      Vehicle.create!(company: company, year: 2026, make: 'Champion', model: "Model #{i}",
                      vin: "VIN#{SecureRandom.hex(6).upcase}", status: 'available', is_deleted: false)
    end
    Brochure.create!(company_id: company.id, title: 'Fall Collection', status: 'active')

    campaign = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'Weekly Inventory Digest',
                                campaign_type: 'blast', from_identity_type: 'User',
                                from_identity_id: user.id, throttle_per_day: 100)
    campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ 'type' => 'text', 'html' => 'x' }])
    campaign.update_columns(status: 'completed')

    location = company.locations.first || company.locations.create!(name: 'Denver', timezone: 'UTC')
    site = Website.create!(company_id: company.id, location_id: location.id, name: 'Summit',
                           slug: "s-#{SecureRandom.hex(4)}", status: 'published')
    site.website_pages.create!(title: 'Spring Sale', page_kind: 'landing')
  end

  def queue_ids(queue_id, as: user)
    WorkqueueService.new(company: company, user: as, queue_id: queue_id).items[:items].map { |r| r[:entity_id] }
  end

  def cast_lead(first_name)
    company.leads.find_by!(first_name: first_name, email: DemoRefresh.email_for(first_name, DemoRefresh::LEADS.values.find { |l| l[:first_name] == first_name }[:last_name]))
  end

  it 'refuses a company that is not listed or not flagged demo' do
    stub_const('ENV', ENV.to_h.merge('DEMO_REFRESH_COMPANY_IDS' => ''))
    expect { described_class.new(company: company, user: user).call }.to raise_error(DemoRefresh::NotAvailable)

    stub_const('ENV', ENV.to_h.merge('DEMO_REFRESH_COMPANY_IDS' => company.id.to_s))
    company.update_columns(is_demo: false)
    expect(described_class.available?(company)).to be(false)
  end

  it "fills the hot queues for whoever pressed it, and nobody else's" do
    described_class.new(company: company, user: user).call

    expect(queue_ids('inventory_hot_interest')).to include(cast_lead('Jenna').id, cast_lead('Marcus').id)
    expect(queue_ids('brochure_hot_interest')).to include(cast_lead('Priya').id)
    expect(queue_ids('engagement_opened_today')).to include(cast_lead('Jenna').id, cast_lead('Hannah').id)
    expect(queue_ids('engagement_clicked_today')).to include(cast_lead('Marcus').id)
    expect(queue_ids('engagement_hot_reopeners')).to eq([cast_lead('Hannah').id])
    expect(queue_ids('engagement_opened_week')).to include(cast_lead('Megan').id)
    expect(queue_ids('engagement_landing_deep')).to eq([cast_lead('Hannah').id])
    expect(queue_ids('leads_inbound_new')).to contain_exactly(cast_lead('Rosa').id, cast_lead('Tyler').id)
    expect(queue_ids('leads_new_24h')).to contain_exactly(cast_lead('Rosa').id, cast_lead('Tyler').id)
    expect(queue_ids('leads_replied')).to eq([cast_lead('Derek').id])
    expect(queue_ids('leads_stale_48h')).to eq([cast_lead('Luis').id])
    expect(queue_ids('contacts_replied').size).to eq(1)
    expect(queue_ids('engagement_contact_opened_today').size).to eq(1)

    expect(queue_ids('inventory_hot_interest', as: other_rep)).to be_empty
    expect(queue_ids('leads_replied', as: other_rep)).to be_empty
  end

  # The activity queues read a database view the test schema does not load,
  # so check the rows that view is built from.
  it 'books tasks today, an overdue call and meetings this week, without inviting the buyer' do
    described_class.new(company: company, user: user).call

    acts = LeadActivity.where(lead_id: company.leads.select(:id), assigned_to_id: user.id)
    today = acts.where(activity_type: 'task', due_date: ..Time.current.end_of_day)
    expect(today.count).to be >= 3
    expect(acts.where(activity_type: 'call').where('due_date < ?', Time.current).count).to eq(1)
    expect(acts.where(activity_type: 'meeting').where(start_time: Time.current.all_day).count).to eq(1)
    expect(acts.where(activity_type: 'meeting').where('start_time > ?', Time.current.end_of_day).count).to eq(2)
    expect(acts.where(remind_customer: true).or(acts.where(send_calendar_invite: true))).to be_empty
  end

  it 'starts the next demo clean, and leaves the rest of the company alone' do
    keeper = company.leads.create!(first_name: 'Real', last_name: 'Buyer', email: 'real@buyer.test',
                                   owner_id: other_rep.id, status: 'new')

    described_class.new(company: company, user: user).call
    lead_count = company.leads.count
    first_run = {
      activities: LeadActivity.count, links: TrackedLink.count,
      sends: CampaignSend.count, messages: Communication.count, visits: PageVisit.count,
    }

    # What a demo does: finish a task, reply to a lead, set a row aside.
    LeadActivity.where(lead_id: cast_lead('Caleb').id).update_all(status: 'completed')
    company.leads.where(id: cast_lead('Rosa').id).update_all(status: 'contacted')
    WorkqueueDismissal.dismiss!(company: company, user: user, entity_type: 'Lead', entity_id: cast_lead('Derek').id)

    described_class.new(company: company, user: user).call

    expect(company.leads.count).to eq(lead_count)
    expect({
      activities: LeadActivity.count, links: TrackedLink.count,
      sends: CampaignSend.count, messages: Communication.count, visits: PageVisit.count,
    }).to eq(first_run)
    expect(LeadActivity.where(lead_id: cast_lead('Caleb').id).pluck(:status).uniq).to eq(['pending'])
    expect(queue_ids('leads_inbound_new')).to include(cast_lead('Rosa').id)
    expect(queue_ids('leads_replied')).to eq([cast_lead('Derek').id])

    expect(keeper.reload.owner_id).to eq(other_rep.id)
  end

  it 'opens deals closing this week and month, a stale deal, quotes out and invoices overdue' do
    described_class.new(company: company, user: user).call

    expect(queue_ids('deals_mine').size).to eq(3)
    expect(queue_ids('deals_closing_week').size).to be >= 1
    expect(queue_ids('deals_closing_month').size).to be >= 1
    expect(queue_ids('deals_stale_30d').size).to eq(1)
    expect(queue_ids('quotes_awaiting_response').size).to eq(2)
    expect(queue_ids('invoices_overdue').size).to eq(2)
    expect(queue_ids('deals_mine', as: other_rep)).to be_empty

    # Never in a state the overdue reminder email picks up.
    expect(company.invoices.where(status: %w[sent viewed])).to be_empty
    expect(InvoiceItem.where(invoice_id: company.invoices.select(:id)).count).to eq(2)
  end

  it 'keeps the same deal, quote and invoice numbers across refreshes, and reopens a deal closed in the demo' do
    described_class.new(company: company, user: user).call
    numbers = -> { [company.deals.order(:id).pluck(:deal_number), company.quotes.order(:id).pluck(:quote_number),
                    company.invoices.order(:id).pluck(:invoice_number)] }
    before = numbers.call

    company.deals.update_all(stage: 'closed_won', won_at: Time.current)
    company.invoices.update_all(status: 'paid', amount_due: 0)
    described_class.new(company: company, user: user).call

    expect(numbers.call).to eq(before)
    expect(queue_ids('deals_mine').size).to eq(3)
    expect(queue_ids('invoices_overdue').size).to eq(2)
  end

  it 'remembers who pressed it, for the nightly job' do
    described_class.new(company: company, user: user).call
    expect(described_class.last_user_id(company)).to eq(user.id)

    allow(DemoRefresh).to receive(:new).and_call_original
    DemoRefreshJob.perform_now
    expect(DemoRefresh).to have_received(:new).with(company: company, user: user)
  end
end
