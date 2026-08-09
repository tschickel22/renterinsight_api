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

  describe 'admin-tier resources' do
    it 'revokes the admin-only ones outright from every non-admin role' do
      described_class.reconcile_system_permissions!

      leaked = Role.system_roles.where.not(key: described_class::ADMIN_ROLE_KEYS).flat_map do |role|
        keys = role.role_permissions.granted.joins(:resource)
                   .where(resources: { key: described_class::ADMIN_ONLY_RESOURCES })
                   .distinct.pluck('resources.key')
        keys.map { |k| "#{role.key}:#{k}" }
      end

      expect(leaked).to be_empty
    end

    # Revoking these outright is what turned a sales persona into a wall of
    # permission-denied toasts: assignee pickers, location filters, labels and
    # custom fields all read them on ordinary screens.
    it 'takes write away on the load-bearing ones but leaves read' do
      described_class.reconcile_system_permissions!
      sales = Role.system_roles.find_by!(key: 'sales_rep')

      described_class::ADMIN_WRITE_ONLY_RESOURCES.each do |key|
        actions = sales.role_permissions.granted.joins(:resource, :action)
                       .where(resources: { key: key }).pluck('actions.key')

        expect(actions).to include('read'), "sales_rep lost read on #{key}"
        expect(actions & %w[create update delete manage]).to be_empty, "sales_rep kept write on #{key}"
      end
    end

    it 'heals a role whose reads were unchecked by hand' do
      described_class.reconcile_system_permissions!
      sales = Role.system_roles.find_by!(key: 'sales_rep')
      ids = Resource.where(key: described_class::ADMIN_WRITE_ONLY_RESOURCES).pluck(:id)
      RolePermission.where(role: sales, resource_id: ids).update_all(granted: false)

      described_class.reconcile_system_permissions!

      reads = sales.role_permissions.granted.joins(:resource, :action)
                   .where(resources: { key: 'users' }, actions: { key: 'read' })
      expect(reads).to exist
    end

    it 'leaves them with company_admin and location_admin' do
      described_class.reconcile_system_permissions!

      described_class::ADMIN_ROLE_KEYS.each do |key|
        role = Role.system_roles.find_by(key: key)
        next unless role

        granted = role.role_permissions.granted.joins(:resource)
                      .where(resources: { key: 'company_settings' }).exists?
        expect(granted).to be(true), "#{key} lost company_settings"
      end
    end

    # Revoked, not deleted, so the top-up pass cannot quietly restore write.
    it 'keeps write revoked across a second reconcile' do
      described_class.reconcile_system_permissions!
      described_class.reconcile_system_permissions!

      sales = Role.system_roles.find_by(key: 'sales_rep')
      writes = sales.role_permissions.granted.joins(:resource, :action)
                    .where(resources: { key: 'company_settings' },
                           actions: { key: %w[create update delete manage] })
      expect(writes).not_to exist
    end

    it 'revokes the admin-only resources outright, read included' do
      described_class.reconcile_system_permissions!

      sales = Role.system_roles.find_by(key: 'sales_rep')
      any = sales.role_permissions.granted.joins(:resource)
                 .where(resources: { key: 'data_import_export' })
      expect(any).not_to exist
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
