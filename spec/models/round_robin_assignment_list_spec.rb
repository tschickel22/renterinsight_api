# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RoundRobinAssignmentList, type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  def make_user(status: 'active')
    User.create!(
      email: "u-#{SecureRandom.hex(4)}@example.com",
      first_name: 'T', last_name: 'U', password: 'Pass1234!',
      company_id: company.id, role: 'sales_rep', status: status
    )
  end

  let!(:u1) { make_user }
  let!(:u2) { make_user }
  let!(:u3) { make_user }

  describe '#next_active_user!' do
    it 'cycles through users in configured order and wraps' do
      list = RoundRobinAssignmentList.create!(company: company, name: 'Sales', user_ids: [u1.id, u2.id, u3.id])

      picks = 5.times.map { list.next_active_user!.id }
      # Sequence should walk u1, u2, u3, u1, u2 — proving both order and wrap.
      expect(picks).to eq([u1.id, u2.id, u3.id, u1.id, u2.id])
    end

    it 'skips inactive users' do
      u2.update!(status: 'inactive')
      list = RoundRobinAssignmentList.create!(company: company, name: 'Sales', user_ids: [u1.id, u2.id, u3.id])

      picks = 4.times.map { list.next_active_user!.id }
      # u2 is inactive, so effective rotation is u1 -> u3 -> u1 -> u3
      expect(picks).to eq([u1.id, u3.id, u1.id, u3.id])
    end

    it 'returns nil when every user is inactive (caller should leave unassigned)' do
      [u1, u2, u3].each { |u| u.update!(status: 'inactive') }
      list = RoundRobinAssignmentList.create!(company: company, name: 'Sales', user_ids: [u1.id, u2.id, u3.id])
      expect(list.next_active_user!).to be_nil
    end

    it 'returns nil for an empty list' do
      list = RoundRobinAssignmentList.create!(company: company, name: 'Empty', user_ids: [])
      expect(list.next_active_user!).to be_nil
    end
  end
end
