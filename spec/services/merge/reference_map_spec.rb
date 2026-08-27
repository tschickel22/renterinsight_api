# frozen_string_literal: true

require 'rails_helper'

# The merge rewrites foreign keys across dozens of tables, so what counts as a
# reference is the single most dangerous thing to get wrong. Both cases below
# are real and were found by running the merge, not by reading the schema.
RSpec.describe Merge::ReferenceMap do
  describe '.direct_references' do
    it 'finds a reference whose column name does not match the table' do
      # leads.converted_account_id points at accounts. A scan for "account_id"
      # never sees it, and a merge that missed it would strand every converted
      # lead on the retired account.
      refs = described_class.direct_references('Account')

      expect(refs).to include(a_hash_including(table: 'leads', column: 'converted_account_id'))
    end

    it 'excludes a same-named column that is not a reference at all' do
      # syndication_partners.account_id is a varchar holding the partner's own
      # external account code. Rewriting it with one of our ids corrupts a feed.
      refs = described_class.direct_references('Account')

      expect(refs).not_to include(a_hash_including(table: 'syndication_partners'))
    end

    it 'still finds the ordinary case' do
      expect(described_class.direct_references('Contact'))
        .to include(a_hash_including(table: 'quotes', column: 'contact_id'))
    end

    it 'never rewrites the merge bookkeeping itself' do
      refs = described_class.direct_references('Contact')
      expect(refs.map { |r| r[:column] }).not_to include('merged_into_id')
    end
  end

  describe '.live_polymorphic_references' do
    it 'reports a polymorphic owner only when rows of that type exist' do
      company = create(:company)
      contact = Contact.create!(company_id: company.id, first_name: 'Bob', last_name: 'Smith')
      Communication.create!(company_id: company.id, communicable: contact, channel: 'sms',
                            direction: 'outbound', body: 'hi',
                            from_address: '+17205551234', to_address: '+13035550000')

      refs = described_class.live_polymorphic_references('Contact')

      expect(refs).to include(
        a_hash_including(table: 'communications', id_column: 'communicable_id', type_column: 'communicable_type')
      )
    end
  end
end
