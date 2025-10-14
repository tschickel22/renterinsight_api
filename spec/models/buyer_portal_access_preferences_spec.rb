# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BuyerPortalAccess, type: :model do
  let(:company) { Company.create!(name: 'Test Company') }
  let(:source) { Source.create!(name: 'Test Source', source_type: 'website', is_active: true) }
  let(:lead) { Lead.create!(first_name: 'Test', last_name: 'Buyer', email: 'buyer@test.com', phone: '555-1234', source: source, company: company) }

  describe 'preference_history serialization' do
    it 'initializes preference_history as empty array on create' do
      portal_access = BuyerPortalAccess.create!(
        buyer: lead,
        email: 'buyer@test.com',
        password: 'Password123!',
        email_opt_in: true,
        sms_opt_in: true,
        marketing_opt_in: true,
        portal_enabled: true
      )

      expect(portal_access.preference_history).to eq([])
    end

    it 'stores preference_history as JSON' do
      portal_access = BuyerPortalAccess.create!(
        buyer: lead,
        email: 'buyer@test.com',
        password: 'Password123!',
        email_opt_in: true,
        sms_opt_in: true,
        marketing_opt_in: true,
        portal_enabled: true
      )

      portal_access.update!(email_opt_in: false)
      portal_access.reload

      expect(portal_access.preference_history).to be_an(Array)
      expect(portal_access.preference_history.first).to be_a(Hash)
    end

    it 'persists preference_history across reloads' do
      portal_access = BuyerPortalAccess.create!(
        buyer: lead,
        email: 'buyer@test.com',
        password: 'Password123!',
        email_opt_in: true,
        sms_opt_in: true,
        marketing_opt_in: true,
        portal_enabled: true
      )

      portal_access.update!(email_opt_in: false)
      history_before = portal_access.preference_history.dup
      
      portal_access.reload
      
      expect(portal_access.preference_history).to eq(history_before)
    end
  end

  describe 'preference change tracking' do
    let(:portal_access) do
      BuyerPortalAccess.create!(
        buyer: lead,
        email: 'buyer@test.com',
        password: 'Password123!',
        email_opt_in: true,
        sms_opt_in: false,
        marketing_opt_in: true,
        portal_enabled: true
      )
    end

    context 'when updating email_opt_in' do
      it 'tracks the change' do
        expect {
          portal_access.update!(email_opt_in: false)
        }.to change { portal_access.preference_history.length }.by(1)
      end

      it 'records timestamp' do
        portal_access.update!(email_opt_in: false)
        last_entry = portal_access.preference_history.last

        expect(last_entry['timestamp']).to be_present
        expect(last_entry['timestamp']).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
      end

      it 'records from value' do
        portal_access.update!(email_opt_in: false)
        last_entry = portal_access.preference_history.last

        expect(last_entry['changes']['email_opt_in']['from']).to eq(true)
      end

      it 'records to value' do
        portal_access.update!(email_opt_in: false)
        last_entry = portal_access.preference_history.last

        expect(last_entry['changes']['email_opt_in']['to']).to eq(false)
      end
    end

    context 'when updating sms_opt_in' do
      it 'tracks the change' do
        expect {
          portal_access.update!(sms_opt_in: true)
        }.to change { portal_access.preference_history.length }.by(1)
      end

      it 'records correct field name' do
        portal_access.update!(sms_opt_in: true)
        last_entry = portal_access.preference_history.last

        expect(last_entry['changes']).to have_key('sms_opt_in')
      end
    end

    context 'when updating marketing_opt_in' do
      it 'tracks the change' do
        expect {
          portal_access.update!(marketing_opt_in: false)
        }.to change { portal_access.preference_history.length }.by(1)
      end
    end

    context 'when updating portal_enabled' do
      it 'tracks the change' do
        expect {
          portal_access.update!(portal_enabled: false)
        }.to change { portal_access.preference_history.length }.by(1)
      end

      it 'records portal_enabled change' do
        portal_access.update!(portal_enabled: false)
        last_entry = portal_access.preference_history.last

        expect(last_entry['changes']).to have_key('portal_enabled')
        expect(last_entry['changes']['portal_enabled']['from']).to eq(true)
        expect(last_entry['changes']['portal_enabled']['to']).to eq(false)
      end
    end

    context 'when updating multiple preferences' do
      it 'tracks all changes in single entry' do
        expect {
          portal_access.update!(
            email_opt_in: false,
            sms_opt_in: true,
            marketing_opt_in: false
          )
        }.to change { portal_access.preference_history.length }.by(1)
      end

      it 'records all changed fields' do
        portal_access.update!(
          email_opt_in: false,
          sms_opt_in: true
        )
        
        last_entry = portal_access.preference_history.last
        
        expect(last_entry['changes'].keys).to contain_exactly('email_opt_in', 'sms_opt_in')
      end

      it 'uses single timestamp for all changes' do
        portal_access.update!(
          email_opt_in: false,
          sms_opt_in: true,
          marketing_opt_in: false
        )
        
        last_entry = portal_access.preference_history.last
        
        expect(last_entry['timestamp']).to be_present
        expect(last_entry['changes'].length).to eq(3)
      end
    end

    context 'when updating non-preference fields' do
      it 'does not track email changes' do
        expect {
          portal_access.update!(email: 'newemail@test.com')
        }.not_to change { portal_access.preference_history.length }
      end

      it 'does not track password changes' do
        expect {
          portal_access.update!(password: 'NewPassword123!')
        }.not_to change { portal_access.preference_history.length }
      end

      it 'does not track login_count changes' do
        expect {
          portal_access.update!(login_count: 5)
        }.not_to change { portal_access.preference_history.length }
      end
    end

    context 'when no changes occur' do
      it 'does not add to history when saving without changes' do
        portal_access.save!
        history_before = portal_access.preference_history.dup
        
        portal_access.save!
        portal_access.reload
        
        expect(portal_access.preference_history).to eq(history_before)
      end
    end
  end

  describe 'validations' do
    let(:portal_access) do
      BuyerPortalAccess.create!(
        buyer: lead,
        email: 'buyer@test.com',
        password: 'Password123!',
        email_opt_in: true,
        sms_opt_in: false,
        marketing_opt_in: true,
        portal_enabled: true
      )
    end

    it 'validates email_opt_in is boolean' do
      expect(portal_access).to be_valid
      portal_access.email_opt_in = nil
      expect(portal_access).not_to be_valid
    end

    it 'validates sms_opt_in is boolean' do
      expect(portal_access).to be_valid
      portal_access.sms_opt_in = nil
      expect(portal_access).not_to be_valid
    end

    it 'validates marketing_opt_in is boolean' do
      expect(portal_access).to be_valid
      portal_access.marketing_opt_in = nil
      expect(portal_access).not_to be_valid
    end

    it 'validates portal_enabled is boolean' do
      expect(portal_access).to be_valid
      portal_access.portal_enabled = nil
      expect(portal_access).not_to be_valid
    end
  end

  describe 'scopes' do
    let!(:active_access) do
      BuyerPortalAccess.create!(
        buyer: lead,
        email: 'active@test.com',
        password: 'Password123!',
        email_opt_in: true,
        sms_opt_in: true,
        marketing_opt_in: true,
        portal_enabled: true
      )
    end

    let(:lead2) { Lead.create!(first_name: 'Inactive', last_name: 'User', email: 'inactive@test.com', phone: '555-5678', source: source, company: company) }
    let!(:inactive_access) do
      BuyerPortalAccess.create!(
        buyer: lead2,
        email: 'inactive@test.com',
        password: 'Password123!',
        email_opt_in: false,
        sms_opt_in: false,
        marketing_opt_in: false,
        portal_enabled: false
      )
    end

    it 'filters active portals' do
      expect(BuyerPortalAccess.active).to include(active_access)
      expect(BuyerPortalAccess.active).not_to include(inactive_access)
    end

    it 'filters inactive portals' do
      expect(BuyerPortalAccess.inactive).to include(inactive_access)
      expect(BuyerPortalAccess.inactive).not_to include(active_access)
    end

    it 'filters email_enabled' do
      expect(BuyerPortalAccess.email_enabled).to include(active_access)
      expect(BuyerPortalAccess.email_enabled).not_to include(inactive_access)
    end

    it 'filters sms_enabled' do
      expect(BuyerPortalAccess.sms_enabled).to include(active_access)
      expect(BuyerPortalAccess.sms_enabled).not_to include(inactive_access)
    end

    it 'filters marketing_enabled' do
      expect(BuyerPortalAccess.marketing_enabled).to include(active_access)
      expect(BuyerPortalAccess.marketing_enabled).not_to include(inactive_access)
    end
  end

  describe '#preference_summary' do
    let(:portal_access) do
      BuyerPortalAccess.create!(
        buyer: lead,
        email: 'buyer@test.com',
        password: 'Password123!',
        email_opt_in: true,
        sms_opt_in: false,
        marketing_opt_in: true,
        portal_enabled: true
      )
    end

    it 'returns hash with all preference fields' do
      summary = portal_access.preference_summary
      
      expect(summary).to be_a(Hash)
      expect(summary.keys).to contain_exactly(
        :email_opt_in, :sms_opt_in, :marketing_opt_in, :portal_enabled
      )
    end

    it 'returns current preference values' do
      summary = portal_access.preference_summary
      
      expect(summary[:email_opt_in]).to eq(true)
      expect(summary[:sms_opt_in]).to eq(false)
      expect(summary[:marketing_opt_in]).to eq(true)
      expect(summary[:portal_enabled]).to eq(true)
    end
  end

  describe '#recent_preference_changes' do
    let(:portal_access) do
      BuyerPortalAccess.create!(
        buyer: lead,
        email: 'buyer@test.com',
        password: 'Password123!',
        email_opt_in: true,
        sms_opt_in: false,
        marketing_opt_in: true,
        portal_enabled: true
      )
    end

    it 'returns empty array when no history' do
      expect(portal_access.recent_preference_changes).to eq([])
    end

    it 'returns history entries' do
      portal_access.update!(email_opt_in: false)
      portal_access.update!(sms_opt_in: true)
      
      history = portal_access.recent_preference_changes
      expect(history.length).to eq(2)
    end

    it 'limits to 50 entries by default' do
      60.times do |i|
        portal_access.update!(email_opt_in: i.even?)
      end
      
      history = portal_access.recent_preference_changes
      expect(history.length).to eq(50)
    end

    it 'accepts custom limit' do
      10.times do |i|
        portal_access.update!(email_opt_in: i.even?)
      end
      
      history = portal_access.recent_preference_changes(5)
      expect(history.length).to eq(5)
    end

    it 'returns most recent entries' do
      portal_access.update!(email_opt_in: false)
      sleep 0.1
      portal_access.update!(sms_opt_in: true)
      
      history = portal_access.recent_preference_changes
      
      # Last entry should have sms_opt_in change
      expect(history.last['changes']).to have_key('sms_opt_in')
    end
  end
end
