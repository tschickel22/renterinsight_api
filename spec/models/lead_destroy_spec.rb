# frozen_string_literal: true

require 'rails_helper'

# A lead created from an intake form could not be deleted. intake_submissions
# and lead_tasks both carry a foreign key to leads with no ON DELETE behaviour,
# and Lead declared no association for either, so Postgres refused the delete
# and the request died as a 500 PG::ForeignKeyViolation. It looked like a
# permissions problem — it was reproducible as company admin AND platform admin,
# because authorization was never involved.
RSpec.describe Lead, '#destroy with child records', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:lead) do
    company.leads.create!(first_name: 'Rylee', last_name: 'Test', email: "r-#{SecureRandom.hex(3)}@example.com")
  end
  let(:form) do
    IntakeForm.create!(company_id: company.id, name: 'Pre-Qual', schema: [], is_active: true,
                       auto_create_lead: true, auto_create_activity: false)
  end

  it 'deletes a lead that came from an intake form' do
    submission = IntakeSubmission.create!(intake_form_id: form.id, data: { 'x' => 1 }, lead_id: lead.id)

    expect { lead.destroy! }.not_to raise_error
    expect(Lead.find_by(id: lead.id)).to be_nil
    expect(IntakeSubmission.find_by(id: submission.id)).to be_present
  end

  # The submission records what the visitor actually sent. It predates the lead
  # (lead_id is nullable for exactly that reason) and outliving it is correct —
  # destroying it would throw away the only record of the enquiry.
  it 'keeps the submission and just unlinks it' do
    submission = IntakeSubmission.create!(intake_form_id: form.id, data: { 'x' => 1 }, lead_id: lead.id)

    lead.destroy!

    expect(submission.reload.lead_id).to be_nil
    expect(submission.data).to eq({ 'x' => 1 })
  end

  it 'deletes lead tasks along with the lead' do
    task = LeadTask.create!(lead_id: lead.id, title: 'Call back')

    lead.destroy!

    expect(LeadTask.find_by(id: task.id)).to be_nil
  end

  it 'still deletes a lead with no children at all' do
    expect { lead.destroy! }.not_to raise_error
  end

  # Guard against the next table that gets a foreign key to leads without a
  # matching dependent option. Every FK child must be covered by an association
  # that clears it, or deleting a lead 500s again.
  it 'has a dependent option for every table with a foreign key to leads' do
    fk_children = ActiveRecord::Base.connection.execute(<<~SQL).map { |r| r['table_name'] }.uniq
      SELECT tc.table_name
      FROM information_schema.table_constraints tc
      JOIN information_schema.constraint_column_usage ccu
        ON tc.constraint_name = ccu.constraint_name
      WHERE tc.constraint_type = 'FOREIGN KEY' AND ccu.table_name = 'leads'
    SQL

    covered = Lead.reflect_on_all_associations
                  .select { |a| a.options[:dependent].present? }
                  .map { |a| a.klass.table_name rescue nil }
                  .compact

    expect(fk_children - covered).to eq([]),
      "these tables reference leads with no dependent option, so deleting a lead will 500: #{(fk_children - covered).join(', ')}"
  end
end
