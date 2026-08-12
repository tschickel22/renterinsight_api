# frozen_string_literal: true

require 'rails_helper'

# A rep working the queue needs to see that a lead is already going nowhere
# before spending time on it. The row carries the lead's pipeline status
# separately from :status, which means different things on different queues.
RSpec.describe 'Lead status on workqueue rows', type: :model do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "wqs-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Reid', last_name: 'Tester')
  end

  def rows(queue)
    WorkqueueService.new(company: company, user: user, queue_id: queue).items[:items]
  end

  describe 'lead rows' do
    it 'carries the pipeline status' do
      lead = create(:lead, company: company, owner_id: user.id, status: 'new')

      row = rows('leads_mine').find { |r| r[:entity_id] == lead.id }
      expect(row[:lead_status]).to eq('new')
    end

    # The status a dealer invents is exactly the one the hardcoded skip list
    # below does not know about, so it is the case that actually reaches a rep.
    it 'carries a tenant-defined status through untouched' do
      lead = create(:lead, company: company, owner_id: user.id, status: 'not_a_fit')

      row = rows('leads_mine').find { |r| r[:entity_id] == lead.id }
      expect(row[:lead_status]).to eq('not_a_fit')
    end
  end

  # Exercised against the normalizer rather than the queue, because task rows
  # come from the workqueue_activities VIEW, which is created by raw SQL in a
  # migration and therefore absent from schema.rb and from the test database.
  # The end-to-end path was checked by hand in development; this pins the part
  # that can be pinned, which is where the parent's status is read from.
  describe 'task rows' do
    ActivityRow = Struct.new(:uid, :source_table, :source_id, :parent_type, :parent_id, :subject,
                             :activity_type, :status, :priority, :due_date, :start_time, :updated_at,
                             keyword_init: true)

    def normalize_activity_row(parent_type:, parents:)
      service = WorkqueueService.new(company: company, user: user)
      service.instance_variable_set(:@activity_parents, parents)
      service.send(:normalize_activity, ActivityRow.new(
                                          uid: 'lead_activity-1', source_table: 'lead_activities', source_id: 1,
                                          parent_type: parent_type, parent_id: 42, subject: 'Follow up',
                                          activity_type: 'task', status: 'pending', priority: 'medium',
                                          due_date: Date.current, start_time: nil, updated_at: Time.current
                                        ))
    end

    it "carries the parent lead's status so the task can be closed on sight" do
      row = normalize_activity_row(
        parent_type: 'Lead',
        parents: { 'Lead' => { 42 => { name: 'A B', phone: nil, email: nil, status: 'not_a_fit' } } }
      )

      expect(row[:lead_status]).to eq('not_a_fit')
    end

    it 'leaves it empty for a parent that has no pipeline status' do
      row = normalize_activity_row(
        parent_type: 'Deal',
        parents: { 'Deal' => { 42 => { name: 'A Deal', phone: nil, email: nil, status: nil } } }
      )

      expect(row[:lead_status]).to be_nil
    end

    it 'survives a parent that was not preloaded' do
      row = normalize_activity_row(parent_type: 'Lead', parents: {})

      expect(row[:lead_status]).to be_nil
    end
  end

  # Documents today's behaviour rather than endorsing it: these queues skip a
  # hardcoded set of English status keys, so a dealer's own dead-end status
  # (not_a_fit above) still reaches the rep and is precisely why the badge is
  # needed. The tenant-configured is_excluded flag is not consulted here yet.
  describe 'the hardcoded skip list' do
    it 'hides the built-in dead-end statuses from lead queues' do
      %w[converted lost unqualified].each do |status|
        lead = create(:lead, company: company, owner_id: user.id, status: status)
        expect(rows('leads_mine').map { |r| r[:entity_id] }).not_to include(lead.id)
      end
    end

    it 'still surfaces a tenant status that means the same thing' do
      lead = create(:lead, company: company, owner_id: user.id, status: 'do_not_contact')

      expect(rows('leads_mine').map { |r| r[:entity_id] }).to include(lead.id)
    end
  end
end
