# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Role, '.reconcile_system_permissions!' do
  before do
    Resource.seed_defaults
    Action.seed_defaults
    Scope.seed_defaults
    Role.seed_defaults
  end

  let(:admin) { Role.system_roles.find_by(key: 'company_admin') }

  it 'gives company_admin every active resource' do
    described_class.reconcile_system_permissions!

    covered = admin.role_permissions.granted.joins(:resource).distinct.pluck('resources.key')
    expect(covered).to match_array(Resource.active.pluck(:key))
  end

  # The gap this exists to close: seed_defaults bails out once system roles are
  # present, so a resource added later never reaches an existing database.
  it 'picks up a resource added after the initial seed' do
    Resource.create!(key: 'late_arrival', name: 'Late Arrival', category: 'operations', active: true)

    expect { described_class.reconcile_system_permissions! }
      .to change { admin.role_permissions.granted.joins(:resource).where(resources: { key: 'late_arrival' }).count }
      .from(0)

    # And the one-shot really is a one-shot, which is why the above is needed.
    expect { Role.seed_defaults }.not_to(change { RolePermission.count })
  end

  it 'gives every system role read on notifications' do
    described_class.reconcile_system_permissions!

    Role.system_roles.each do |role|
      has_read = role.role_permissions.granted
                     .joins(:resource, :action)
                     .exists?(resources: { key: 'notifications' }, actions: { key: 'read' })
      expect(has_read).to be(true), "#{role.key} cannot read notifications"
    end
  end

  # Reconcile is additive on purpose. Production has 4 company_managers using it
  # as a delegated admin and 24 sales reps with the activity log; taking those
  # away buys production nothing, so narrowing lives on the demo copies.
  describe 'what it must never remove' do
    it 'leaves the admin-tier grants of the shipped templates alone' do
      described_class.reconcile_system_permissions!
      manager = Role.system_roles.find_by!(key: 'company_manager')
      before = manager.role_permissions.granted.count

      described_class.reconcile_system_permissions!

      expect(manager.role_permissions.granted.count).to be >= before
    end

    it 'never reduces any role\'s granted count' do
      described_class.reconcile_system_permissions!
      counts = Role.all.to_h { |r| [r.id, r.role_permissions.granted.count] }

      described_class.reconcile_system_permissions!

      Role.all.each do |role|
        expect(role.role_permissions.granted.count).to be >= counts.fetch(role.id, 0)
      end
    end
  end

  describe '.narrow_for_demo!' do
    let(:demo) do
      company = Company.create!(name: "Co-#{SecureRandom.hex(4)}")
      role = Role.create!(company_id: company.id, key: 'demo_sales_rep', name: 'Demo Sales',
                          tier: 'location', active: true)
      described_class.grant_full_permissions!(role)
      role
    end

    it 'strips the admin-only resources entirely' do
      described_class.narrow_for_demo!(demo)

      left = demo.role_permissions.granted.joins(:resource)
                 .where(resources: { key: described_class::ADMIN_ONLY_RESOURCES })
      expect(left).not_to exist
    end

    it 'takes write but leaves read on the load-bearing three' do
      described_class.narrow_for_demo!(demo)

      described_class::ADMIN_WRITE_ONLY_RESOURCES.each do |key|
        actions = demo.role_permissions.granted.joins(:resource, :action)
                      .where(resources: { key: key }).pluck('actions.key')
        expect(actions).to include('read'), "demo role lost read on #{key}"
        expect(actions & %w[create update delete manage]).to be_empty, "demo role kept write on #{key}"
      end
    end

    it 'refuses to narrow an admin role' do
      admin = Role.system_roles.find_by!(key: 'company_admin')
      before = admin.role_permissions.granted.count

      described_class.narrow_for_demo!(admin)

      expect(admin.role_permissions.granted.count).to eq(before)
    end
  end

  # A company's own role missing these reads is broken, not narrow, and the
  # first version of this only fixed the shipped templates.
  it 'asserts the load-bearing reads on a company-scoped role too' do
    company = Company.create!(name: "Co-#{SecureRandom.hex(4)}")
    custom = Role.create!(company_id: company.id, key: "rep-#{SecureRandom.hex(3)}",
                          name: 'Custom Rep', tier: 'location', active: true)

    described_class.reconcile_system_permissions!

    reads = custom.role_permissions.granted.joins(:resource, :action)
                  .where(resources: { key: described_class::ADMIN_WRITE_ONLY_RESOURCES },
                         actions: { key: 'read' })
    expect(reads.count).to eq(described_class::ADMIN_WRITE_ONLY_RESOURCES.size)
  end

  # update_all skips the after_save hook that normally clears these, so without
  # an explicit sweep the database is right and every process still says no.
  it 'clears the cached permission answers' do
    expect(Rails.cache).to receive(:delete_matched).with('permissions:*')

    described_class.reconcile_system_permissions!
  end

  # Production reproduced exactly: the notifications resource had never been
  # seeded, the guard for that block was a bare `return`, and the whole method
  # bailed out before asserting the reads or sweeping the cache. It reported
  # success and changed nothing.
  it 'still asserts the reads when the notifications resource is missing' do
    Resource.where(key: 'notifications').destroy_all
    sales = Role.system_roles.find_by!(key: 'sales_rep')
    ids = Resource.where(key: described_class::ADMIN_WRITE_ONLY_RESOURCES).pluck(:id)
    RolePermission.where(role: sales, resource_id: ids).destroy_all

    described_class.reconcile_system_permissions!

    reads = sales.role_permissions.granted.joins(:resource, :action)
                 .where(resources: { key: described_class::ADMIN_WRITE_ONLY_RESOURCES },
                        actions: { key: 'read' })
    expect(reads.count).to eq(described_class::ADMIN_WRITE_ONLY_RESOURCES.size)
  end

  it 'is idempotent' do
    described_class.reconcile_system_permissions!

    expect { described_class.reconcile_system_permissions! }.not_to(change { RolePermission.count })
  end

  # Narrowing a company_admin by revoking is how a persona gets shaped, so a
  # re-seed must not resurrect what was deliberately turned off, and must not
  # collide with the unique index on (role, resource, action, scope).
  it 'leaves an explicit revoke alone instead of raising or re-granting' do
    campaigns = Resource.find_by!(key: 'campaigns')
    described_class.reconcile_system_permissions!
    admin.role_permissions.joins(:resource).where(resources: { key: 'campaigns' }).update_all(granted: false)

    expect { described_class.reconcile_system_permissions! }.not_to raise_error

    still_revoked = admin.role_permissions.where(resource: campaigns).none?(&:granted)
    expect(still_revoked).to be true
  end
end
