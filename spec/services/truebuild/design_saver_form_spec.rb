# frozen_string_literal: true

require 'rails_helper'

# The TrueBuild form made for a dealer who never turned the play on names the
# company's first admin, so a saved design's lead is owned and announced.
RSpec.describe Truebuild::DesignSaver, '.form_for' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }

  def user(role: 'sales_rep', status: 'active')
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'U', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: role, status: status)
  end

  it 'notifies the first active admin by the role column' do
    user
    user(role: 'company_admin', status: 'inactive')
    admin = user(role: 'company_admin')
    user(role: 'company_admin')

    expect(described_class.form_for(company).notified_user_id).to eq(admin.id)
  end

  it 'finds an RBAC company admin' do
    user
    rbac = user
    role = Role.find_or_create_by!(key: 'company_admin', tier: 'company') { |r| r.name = 'Company Admin' }
    UserRoleAssignment.create!(user: rbac, role: role, tier: 'company', company_id: company.id)

    expect(described_class.form_for(company).notified_user_id).to eq(rbac.id)
  end

  it 'keeps the form a dealer already has, and its choice' do
    described_class.form_for(company)
    form = described_class.form_for(company)
    form.update!(notified_user_id: (rep = user).id)
    user(role: 'company_admin')

    expect(described_class.form_for(company).notified_user_id).to eq(rep.id)
  end
end
