# frozen_string_literal: true

require 'rails_helper'

# max_users was saved and shown on the tenant screen but nothing enforced it.
RSpec.describe 'Company max_users', type: :model do
  let(:company) { Company.create!(name: "Seats #{SecureRandom.hex(4)}", industry: 'manufactured_housing', max_users: 2) }

  def add_user(role: 'staff', status: 'active', **attrs)
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'U', last_name: 'S',
                 password: 'Pass1234!', company_id: company.id, role: role, status: status, **attrs)
  end

  before { 2.times { add_user } }

  it 'refuses a new active user once the company is full' do
    expect { add_user }.to raise_error(ActiveRecord::RecordInvalid, /has 2 of 2 users/)
  end

  it 'refuses reactivating a user when the company is full' do
    parked = add_user(status: 'inactive')
    expect(parked.update(status: 'active')).to be(false)
    expect(parked.errors.full_messages.join).to include('2 of 2 users')
  end

  it 'still lets existing users be edited when full' do
    user = company.users.first
    expect(user.update(first_name: 'Renamed')).to be(true)
  end

  it 'does not count platform admins or portal clients' do
    expect { add_user(role: 'platform_admin') }.not_to raise_error
    expect { add_user(role: 'client') }.not_to raise_error
    expect(company.active_users_count).to eq(2)
  end

  it 'frees the seat when a user is deactivated' do
    company.users.first.update!(status: 'inactive')
    expect { add_user }.not_to raise_error
  end

  it 'applies on the enterprise tier too' do
    company.update!(subscription_tier: 'enterprise')
    expect { add_user }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'treats a blank or zero limit as no limit' do
    company.update!(max_users: 0)
    expect { 3.times { add_user } }.not_to raise_error
  end

  describe 'invitations' do
    let(:service) { InvitationService.new(company: company, invited_by: company.users.first) }

    def invite(email)
      service.create_invitation(invitation_type: 'company_user', email: email, skip_send: true)
    end

    it 'refuses to invite when the company is full' do
      result = invite('new@example.com')
      expect(result[:success]).to be(false)
      expect(result[:error]).to include('2 of 2 users')
    end

    it 'counts invitations not yet accepted against the free seats' do
      company.update!(max_users: 3)
      expect(invite('first@example.com')[:success]).to be(true)
      expect(invite('second@example.com')[:success]).to be(false)
    end
  end
end
