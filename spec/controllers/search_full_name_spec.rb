# frozen_string_literal: true

require 'rails_helper'

# Searching "don kill" for Don Killins came back "No results found" — in global
# search AND in the leads/contacts list filters. Every one of those searches was
# a per-column `first_name ILIKE ? OR last_name ILIKE ?`, and "don kill" is not
# a substring of either column on its own.
#
# The second half of the same bug: the per-type `.limit(5)` had no ORDER BY, so
# against thousands of leads Postgres returned whichever five rows the scan hit
# first. Searching "don" could miss Don entirely.
RSpec.describe Api::V1::SearchController, type: :controller do
  let(:company) { FactoryBot.create(:company) }
  let(:instance) { described_class.new }

  def leads_matching(query)
    company.leads
           .where(instance.person_name_where('leads', extra: %w[email phone company_name]),
                  q: instance.person_name_like(query))
           .order(Arel.sql(instance.person_name_order('leads', query)))
  end

  let!(:don) do
    FactoryBot.create(:lead, company: company, first_name: 'Don', last_name: 'Killins',
                             email: 'dee@donkillins.com', company_name: 'Country Village')
  end

  describe 'matching a full name as typed' do
    it 'finds the lead by "first last"' do
      expect(leads_matching('don kill')).to include(don)
    end

    it 'finds the lead by "last, first" order too' do
      expect(leads_matching('killins don')).to include(don)
    end

    it 'still finds the lead by first name alone' do
      expect(leads_matching('don')).to include(don)
    end

    it 'still finds the lead by last name alone' do
      expect(leads_matching('killins')).to include(don)
    end

    it 'still finds the lead by email' do
      expect(leads_matching('dee@donkillins.com')).to include(don)
    end

    it 'does not match a name that only shares loose fragments' do
      FactoryBot.create(:lead, company: company, first_name: 'Sandra', last_name: 'Donovan')

      expect(leads_matching('don kill').map(&:last_name)).to eq(['Killins'])
    end
  end

  describe 'ordering so a LIMIT keeps the best matches' do
    before do
      # Noise that also contains "don" — under the old unordered LIMIT 5 these
      # could crowd Don Killins out of the results entirely.
      10.times do |i|
        FactoryBot.create(:lead, company: company, first_name: "Brandon#{i}",
                                 last_name: "Landon#{i}", email: "x#{i}@london.example.com")
      end
    end

    it 'puts the exact first-name match ahead of the substring matches' do
      expect(leads_matching('don').first).to eq(don)
    end

    it 'keeps the exact match inside a LIMIT 5' do
      expect(leads_matching('don').limit(5)).to include(don)
    end

    it 'ranks a full-name match first' do
      expect(leads_matching('don killins').first).to eq(don)
    end
  end

  describe 'query characters that are LIKE metacharacters' do
    it 'treats a bare % as a literal, not "match every row"' do
      expect(leads_matching('%')).to be_empty
    end

    it 'treats _ as a literal character rather than a single-char wildcard' do
      expect(leads_matching('d_n')).to be_empty
    end

    it 'still matches a name that genuinely contains an underscore' do
      odd = FactoryBot.create(:lead, company: company, first_name: 'Jo_n', last_name: 'Smith')

      expect(leads_matching('jo_n')).to contain_exactly(odd)
    end

    it 'treats a backslash as a literal instead of escaping the next character' do
      expect { leads_matching('\\').to_a }.not_to raise_error
      expect(leads_matching('\\')).to be_empty
    end
  end

  describe 'contacts use the same matching' do
    def contacts_matching(query)
      company.contacts
             .where(instance.person_name_where('contacts', extra: %w[email phone title department]),
                    q: "%#{query}%")
             .order(Arel.sql(instance.person_name_order('contacts', query)))
    end

    let!(:contact) do
      company.contacts.create!(first_name: 'Don', last_name: 'Killins', email: 'dee@donkillins.com')
    end

    it 'finds the contact by "first last"' do
      expect(contacts_matching('don kill')).to include(contact)
    end
  end
end
