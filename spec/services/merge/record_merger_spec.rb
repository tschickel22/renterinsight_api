# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merge::RecordMerger do
  let(:company)       { create(:company) }
  let(:other_company) { create(:company) }

  def contact(attrs = {})
    Contact.create!({ company_id: company.id, first_name: 'Bob', last_name: 'Smith' }.merge(attrs))
  end

  describe 'tenant isolation' do
    it 'refuses to merge across companies' do
      mine   = contact(email: 'a@x.com')
      theirs = Contact.create!(company_id: other_company.id, first_name: 'Bob', last_name: 'Smith')

      expect { described_class.call(survivor: mine, loser: theirs) }
        .to raise_error(described_class::MergeError, /different companies/)
    end

    it 'refuses to merge a record into itself' do
      c = contact
      expect { described_class.call(survivor: c, loser: c) }
        .to raise_error(described_class::MergeError, /into itself/)
    end

    it 'refuses to merge a record that already lost a merge' do
      survivor = contact
      loser    = contact
      described_class.call(survivor: survivor, loser: loser)

      expect { described_class.call(survivor: contact, loser: loser.reload) }
        .to raise_error(described_class::MergeError, /already been merged/)
    end
  end

  describe 'field survivorship' do
    it 'keeps the survivor values and fills only its blanks from the duplicate' do
      survivor = contact(email: 'keep@x.com', phone: nil)
      loser    = contact(email: 'drop@x.com', phone: '720-555-1234')

      result = described_class.call(survivor: survivor, loser: loser)

      expect(survivor.reload.email).to eq('keep@x.com')   # survivor wins
      expect(survivor.phone).to eq('720-555-1234')        # blank filled from duplicate
      expect(result.fields_taken).to have_key('phone')
      expect(result.fields_taken).not_to have_key('email')
    end

    it 'lets an explicit override beat both records' do
      survivor = contact(email: 'keep@x.com')
      loser    = contact(email: 'drop@x.com')

      described_class.call(survivor: survivor, loser: loser,
                           field_overrides: { 'email' => 'chosen@x.com' })

      expect(survivor.reload.email).to eq('chosen@x.com')
    end

    it 'never copies bookkeeping columns off the duplicate' do
      survivor = contact
      loser    = contact
      original_id = survivor.id

      described_class.call(survivor: survivor, loser: loser)

      expect(survivor.reload.id).to eq(original_id)
      expect(survivor.company_id).to eq(company.id)
      expect(survivor.merged_into_id).to be_nil
    end
  end

  describe 'reparenting' do
    it 'moves related rows off the duplicate onto the survivor' do
      survivor = contact(email: 'keep@x.com')
      loser    = contact(email: 'drop@x.com')

      quote = Quote.create!(company_id: company.id, contact_id: loser.id)
      comm  = Communication.create!(company_id: company.id, communicable: loser,
                                    channel: 'sms', direction: 'outbound', body: 'hi',
                                    from_address: '+17205551234', to_address: '+13035550000')

      result = described_class.call(survivor: survivor, loser: loser)

      expect(quote.reload.contact_id).to eq(survivor.id)
      expect(comm.reload.communicable_id).to eq(survivor.id)
      expect(result.moved.keys).to include('quotes.contact_id')
      expect(result.moved.keys).to include('communications.communicable_id')
    end
  end

  describe 'retiring the duplicate' do
    it 'marks it merged rather than destroying it' do
      survivor = contact
      loser    = contact

      described_class.call(survivor: survivor, loser: loser)

      expect(Contact.find_by(id: loser.id)).to be_present   # still there
      expect(loser.reload.merged_into_id).to eq(survivor.id)
      expect(loser.merged_at).to be_present
      expect(Contact.not_merged).not_to include(loser)
      expect(loser.surviving_record).to eq(survivor)
    end
  end

  describe 'preview' do
    it 'reports what would happen and changes nothing' do
      survivor = contact(phone: nil)
      loser    = contact(phone: '720-555-1234')
      quote    = Quote.create!(company_id: company.id, contact_id: loser.id)

      result = described_class.call(survivor: survivor, loser: loser, preview: true)

      expect(result.moved).to include('quotes.contact_id' => 1)
      expect(result.fields_taken).to have_key('phone')
      expect(quote.reload.contact_id).to eq(loser.id)      # untouched
      expect(survivor.reload.phone).to be_nil
      expect(loser.reload.merged_into_id).to be_nil
    end
  end
end
