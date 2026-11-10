# frozen_string_literal: true

require 'rails_helper'

# A rep's own Google or Outlook calendar on their DealerTide calendar. The rep
# chooses how much shows (nothing, busy, titles, titles and places), because
# managers and admins can open their calendar, and only that much is stored.
RSpec.describe 'Own calendar on the DealerTide calendar', type: :request do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)} Homes", industry: 'manufactured_housing') }
  let!(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Jordan', last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active', busy_feed_url: 'https://calendar.example.com/basic.ics')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:tomorrow) { 1.day.from_now.utc.change(hour: 16) }

  let(:ics) do
    stamp = ->(t) { t.utc.strftime('%Y%m%dT%H%M%SZ') }
    <<~ICS
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      DTSTART:#{stamp.(tomorrow)}
      DTEND:#{stamp.(tomorrow + 1.hour)}
      SUMMARY:Dentist\\, Dr. Lee
      LOCATION:12 Elm St\\; Suite 4
      DESCRIPTION:Bring insurance card
      END:VEVENT
      BEGIN:VEVENT
      DTSTART;VALUE=DATE:#{(tomorrow + 1.day).strftime('%Y%m%d')}
      SUMMARY:Day off
      END:VEVENT
      END:VCALENDAR
    ICS
  end

  def read_feed(user)
    CalendarFeeds::BusyReader.new(user, body: ics).sync!
  end

  def feed_rows(user = rep)
    CalendarBusyBlock.where(user_id: user.id, source: 'feed').order(:starts_at)
  end

  describe 'what the reader keeps' do
    it 'keeps only times when the rep shows nothing or busy' do
      %w[none busy].each do |detail|
        rep.update!(busy_feed_detail: detail)
        read_feed(rep)
        expect(feed_rows.pluck(:title, :place)).to all(eq([nil, nil]))
      end
    end

    it 'keeps titles, not places, for titles' do
      rep.update!(busy_feed_detail: 'titles')
      read_feed(rep)
      expect(feed_rows.pluck(:title, :place)).to eq([['Dentist, Dr. Lee', nil], ['Day off', nil]])
    end

    it 'keeps titles and places for titles and places, and never the description' do
      rep.update!(busy_feed_detail: 'titles_places')
      read_feed(rep)
      expect(feed_rows.first.attributes.slice('title', 'place')).to eq('title' => 'Dentist, Dr. Lee', 'place' => '12 Elm St; Suite 4')
      expect(feed_rows.map(&:attributes).to_s).not_to include('insurance')
    end

    it 'marks all-day events' do
      read_feed(rep)
      expect(feed_rows.pluck(:all_day)).to eq([false, true])
    end
  end

  describe 'the rep choosing in Availability' do
    it 'refuses a choice that is not on the list' do
      patch '/api/v1/my_availability', headers: headers, params: { availability: { busy_feed_detail: 'everything' } }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(rep.reload.busy_feed_detail).to eq('none')
    end

    it 'wipes stored titles and places at once when the rep shows less, and reads again' do
      rep.update!(busy_feed_detail: 'titles_places')
      read_feed(rep)

      expect do
        patch '/api/v1/my_availability', headers: headers, params: { availability: { busy_feed_detail: 'titles' } }.to_json
      end.to have_enqueued_job(BusyFeedSyncJob).with(rep.id)
      expect(feed_rows.pluck(:title, :place).first).to eq(['Dentist, Dr. Lee', nil])
      expect(JSON.parse(response.body)['busy_feed_detail']).to eq('titles')

      patch '/api/v1/my_availability', headers: headers, params: { availability: { busy_feed_detail: 'busy' } }.to_json
      expect(feed_rows.pluck(:title, :place)).to all(eq([nil, nil]))
    end
  end

  describe 'the DealerTide calendar' do
    let(:window) { { start_date: Time.current.beginning_of_day.iso8601, end_date: 4.days.from_now.iso8601 } }

    def events(view: 'my', path: '/api/v1/calendar/events')
      get path, headers: headers, params: window.merge(view: view)
      JSON.parse(response.body)
    end

    def outside(view: 'my')
      events(view: view)['events'].select { |e| e['type'] == 'outside_calendar' }
    end

    it 'shows nothing from a rep who chose to show nothing' do
      read_feed(rep)
      expect(outside).to be_empty
    end

    it 'shows busy times as Busy, read only, with no place' do
      rep.update!(busy_feed_detail: 'busy')
      read_feed(rep)
      first = outside.first
      expect(first).to include('title' => 'Busy', 'location' => nil, 'read_only' => true, 'entity_id' => nil,
                               'entity_name' => "Jordan Rep's own calendar")
      expect(outside.last['all_day']).to be(true)
    end

    it 'shows titles and places when the rep chose them' do
      rep.update!(busy_feed_detail: 'titles_places')
      read_feed(rep)
      expect(outside.first).to include('title' => 'Dentist, Dr. Lee', 'location' => '12 Elm St; Suite 4')
    end

    it 'follows the current choice even before the next read rewrites the rows' do
      rep.update!(busy_feed_detail: 'titles_places')
      read_feed(rep)
      rep.update_columns(busy_feed_detail: 'busy')
      expect(outside.first).to include('title' => 'Busy', 'location' => nil)
    end

    it "shows each rep's own choice on the All calendar" do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: 'Casey', last_name: 'Other', password: 'Pass1234!',
                           company_id: company.id, role: 'company_admin', status: 'active', busy_feed_detail: 'busy')
      private_rep = User.create!(email: "p-#{SecureRandom.hex(4)}@example.com", first_name: 'Pat', last_name: 'Private', password: 'Pass1234!',
                                 company_id: company.id, role: 'company_admin', status: 'active', busy_feed_detail: 'none')
      rep.update!(busy_feed_detail: 'titles')
      [rep, other, private_rep].each { |u| read_feed(u) }

      by_owner = outside(view: 'all').group_by { |e| e.dig('assigned_to', 'id') }
      expect(by_owner.keys).to contain_exactly(rep.id, other.id)
      expect(by_owner[other.id].map { |e| e['title'] }.uniq).to eq(['Busy'])
      expect(by_owner[rep.id].first['title']).to eq('Dentist, Dr. Lee')
    end

    it "never shows another company's reps" do
      elsewhere = Company.create!(name: "Else #{SecureRandom.hex(3)}", industry: 'manufactured_housing')
      stranger = User.create!(email: "s-#{SecureRandom.hex(4)}@example.com", first_name: 'Sam', last_name: 'Else', password: 'Pass1234!',
                              company_id: elsewhere.id, role: 'company_admin', status: 'active', busy_feed_detail: 'titles')
      read_feed(stranger)
      expect(outside(view: 'all')).to be_empty
    end

    it 'can be filtered out by type, and stays out of the stats counts' do
      rep.update!(busy_feed_detail: 'busy')
      read_feed(rep)
      get '/api/v1/calendar/events', headers: headers, params: window.merge(view: 'my', types: ['task'])
      expect(JSON.parse(response.body)['events'].map { |e| e['type'] }).not_to include('outside_calendar')

      get '/api/v1/calendar/stats', headers: headers, params: window.merge(view: 'my')
      expect(JSON.parse(response.body)['by_type']).not_to have_key('outside_calendar')
    end
  end
end
