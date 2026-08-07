# frozen_string_literal: true

require 'rails_helper'

# A brochure is sent to one named person on purpose, so the first open is
# already the signal a rep should act on. Before this queue existed the only
# trace of an open was an anonymous view_count on the brochure itself.
RSpec.describe WorkqueueService, '#brochure_click_signals', type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@x.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:other_user) do
    User.create!(email: "o-#{SecureRandom.hex(4)}@x.com", first_name: 'O', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:service) { described_class.new(company: company, user: user) }

  let(:brochure) do
    Brochure.create!(company_id: company.id, title: 'Fall Collection', status: 'active')
  end

  let(:lead) do
    Lead.create!(company_id: company.id, first_name: 'Jane', last_name: 'Doe',
                 email: 'jane@x.com', owner_id: user.id)
  end

  def tracked_link(entity, clicks:, last_clicked_at:, brochure_record: brochure)
    link = TrackedLink.create_for_brochure!(
      company: company,
      brochure: brochure_record,
      url: 'https://example.com/b/abc',
      entity_type: entity.class.name,
      entity_id: entity.id
    )
    link.update_columns(click_count: clicks, last_clicked_at: last_clicked_at,
                        first_clicked_at: last_clicked_at)
    link
  end

  def rows
    service.send(:brochure_click_signals)
  end

  it 'surfaces a lead who opened a brochure we sent them' do
    tracked_link(lead, clicks: 1, last_clicked_at: 2.hours.ago)

    item = rows.first
    expect(rows.size).to eq(1)
    expect(item[:entity_type]).to eq('lead')
    expect(item[:entity_id]).to eq(lead.id)
    expect(item[:title]).to eq('Jane Doe')
    expect(item[:subtitle]).to include('Fall Collection')
    expect(item[:link]).to eq("/crm/leads/#{lead.id}")
  end

  it 'ignores a link that was sent but never clicked' do
    TrackedLink.create_for_brochure!(
      company: company, brochure: brochure, url: 'https://example.com/b/abc',
      entity_type: 'Lead', entity_id: lead.id
    )

    expect(rows).to be_empty
  end

  it 'ignores clicks older than the 48 hour window' do
    tracked_link(lead, clicks: 2, last_clicked_at: 3.days.ago)

    expect(rows).to be_empty
  end

  it "leaves out another rep's lead — the Workqueue is a personal inbox" do
    lead.update!(owner_id: other_user.id)
    tracked_link(lead, clicks: 1, last_clicked_at: 1.hour.ago)

    expect(rows).to be_empty
  end

  it 'collapses the email and SMS links for one person into a single row and sums the opens' do
    tracked_link(lead, clicks: 1, last_clicked_at: 5.hours.ago)
    tracked_link(lead, clicks: 2, last_clicked_at: 1.hour.ago)

    item = rows.first
    expect(rows.size).to eq(1)
    expect(item[:subtitle]).to include('3x')
    expect(item[:badge]).to include('3 opens')
    expect(item[:last_activity_at]).to be_within(1.minute).of(1.hour.ago)
  end

  it 'flags three or more opens as high priority' do
    tracked_link(lead, clicks: 3, last_clicked_at: 1.hour.ago)

    expect(rows.first[:priority]).to eq('high')
  end

  it 'keeps a contact and a lead on separate rows' do
    contact = Contact.create!(company_id: company.id, first_name: 'Sam', last_name: 'Ray',
                              email: 'sam@x.com', owner_id: user.id)
    tracked_link(lead, clicks: 1, last_clicked_at: 2.hours.ago)
    tracked_link(contact, clicks: 1, last_clicked_at: 1.hour.ago)

    expect(rows.map { |r| r[:entity_type] }).to contain_exactly('lead', 'contact')
    expect(rows.first[:entity_type]).to eq('contact') # most recent first
  end

  it 'ignores brochure links belonging to another company' do
    other_company = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
    other_brochure = Brochure.create!(company_id: other_company.id, title: 'Theirs', status: 'active')
    link = TrackedLink.create_for_brochure!(
      company: other_company, brochure: other_brochure, url: 'https://example.com/b/xyz',
      entity_type: 'Lead', entity_id: lead.id
    )
    link.update_columns(click_count: 4, last_clicked_at: 1.hour.ago)

    expect(rows).to be_empty
  end

  it 'exposes the queue through the public items pipeline' do
    tracked_link(lead, clicks: 1, last_clicked_at: 1.hour.ago)

    result = described_class.new(company: company, user: user, queue_id: 'brochure_hot_interest').items
    expect(result[:meta][:total]).to eq(1)
    expect(result[:items].first[:entity_id]).to eq(lead.id)
  end
end
