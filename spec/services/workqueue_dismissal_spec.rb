# frozen_string_literal: true

require 'rails_helper'

# "Save and remove from workqueue" has to mean removed for now, not removed.
# The whole design rests on one comparison: a dismissal hides a row only while
# it is at or after the freshness of whatever put that row in front of the
# user. These cover both directions of that comparison, because a dismissal
# that never lifts would quietly bury live leads.
RSpec.describe 'Workqueue dismissals', type: :model do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "wq-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Reid', last_name: 'Tester')
  end
  let(:other_user) do
    User.create!(email: "wq2-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Hayden', last_name: 'Tester')
  end
  let(:lead) { create(:lead, company: company, owner_id: user.id, status: 'new') }

  def queue_ids(queue, as: user)
    WorkqueueService.new(company: company, user: as, queue_id: queue)
                    .items[:items].map { |i| i[:entity_id] || i['entity_id'] }
  end

  def dismiss!(at: Time.current, target: lead, as: user, type: 'Lead')
    WorkqueueDismissal.dismiss!(company: company, user: as, entity_type: type,
                                entity_id: target.id, at: at)
  end

  describe 'a queue built from the record itself' do
    before { lead.update_columns(last_activity_at: 2.hours.ago, updated_at: 2.hours.ago) }

    it 'shows the lead before anything is dismissed' do
      expect(queue_ids('leads_mine')).to include(lead.id)
    end

    it 'hides it once the user sets it aside' do
      dismiss!(at: 1.minute.ago)

      expect(queue_ids('leads_mine')).not_to include(lead.id)
    end

    it 'brings it back when the record sees newer activity' do
      dismiss!(at: 1.hour.ago)
      lead.update_columns(last_activity_at: Time.current, updated_at: Time.current)

      expect(queue_ids('leads_mine')).to include(lead.id)
    end

    it 'keeps it hidden for the user who dismissed it only' do
      other_lead = create(:lead, company: company, owner_id: other_user.id, status: 'new')
      other_lead.update_columns(last_activity_at: 2.hours.ago, updated_at: 2.hours.ago)
      dismiss!(at: 1.minute.ago, target: other_lead, as: user)

      expect(queue_ids('leads_mine', as: other_user)).to include(other_lead.id)
    end
  end

  describe 'a queue built from an engagement signal' do
    # These compare against the moment of the signal, not the record's last
    # activity, so a fresh open resurfaces a lead nobody has edited since.
    it 'hides a lead dismissed after the open, and restores it after a newer one' do
      service = WorkqueueService.new(company: company, user: user)
      recency = { lead.id => 3.hours.ago }

      dismiss!(at: 2.hours.ago)
      expect(service.send(:reject_dismissed_recency, recency, 'Lead')).to be_empty

      newer = { lead.id => 1.hour.ago }
      expect(service.send(:reject_dismissed_recency, newer, 'Lead')).to include(lead.id)
    end
  end

  describe 'a hash-built queue' do
    it 'compares against the signal carried on the row' do
      service = WorkqueueService.new(company: company, user: user)
      row = { entity_type: 'lead', entity_id: lead.id, last_activity_at: 3.hours.ago }

      dismiss!(at: 2.hours.ago)
      expect(service.send(:reject_dismissed_hash_items, [row])).to be_empty

      fresher = row.merge(last_activity_at: 1.hour.ago)
      expect(service.send(:reject_dismissed_hash_items, [fresher])).to eq([fresher])
    end
  end

  describe WorkqueueDismissal do
    it 'moves the marker forward instead of duplicating the row' do
      first = dismiss!(at: 2.hours.ago)
      second = dismiss!(at: Time.current)

      expect(second.id).to eq(first.id)
      expect(WorkqueueDismissal.for_user(user).count).to eq(1)
      expect(second.dismissed_at).to be > first.reload.dismissed_at - 1.second
    end

    it 'refuses an entity type no queue can produce' do
      record = WorkqueueDismissal.new(company: company, user: user, entity_type: 'Sasquatch',
                                      entity_id: 1, dismissed_at: Time.current)

      expect(record).not_to be_valid
    end
  end
end
