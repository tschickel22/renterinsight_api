# frozen_string_literal: true

require 'rails_helper'

# Grouped reports (E118): group and add up, with every field checked against
# the module's reportable fields, since group and order clauses cannot take
# bind parameters.
RSpec.describe ReportEngine do
  let(:company) { Company.create!(name: "Rep-#{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:ana) { company.users.create!(email: "ana-#{SecureRandom.hex(3)}@example.com", first_name: 'Ana', last_name: 'Rep', password: 'Pass1234!', role: 'user', status: 'active') }
  let(:bo) { company.users.create!(email: "bo-#{SecureRandom.hex(3)}@example.com", first_name: 'Bo', last_name: 'Rep', password: 'Pass1234!', role: 'user', status: 'active') }
  let(:buyer) { company.contacts.create!(first_name: 'Cy', last_name: 'Buyer') }

  before do
    [[ana, 100_000, '2026-09-10'], [ana, 50_000, '2026-10-05'], [bo, 80_000, '2026-10-20']].each do |owner, price, closed|
      company.deals.create!(name: "D #{price}", contact_id: buyer.id, owner_id: owner.id, selling_price: price,
                            stage: 'closed_won', actual_close_date: Date.parse(closed))
    end
  end

  def run(extra = {})
    described_class.run({ module: 'deals', company_id: company.id }.merge(extra))
  end

  it 'groups by salesperson with totals, names instead of ids, largest first' do
    out = run(group_by: 'owner_id', aggregates: [{ fn: 'count' }, { fn: 'sum', field: 'selling_price' }, { fn: 'avg', field: 'selling_price' }])
    expect(out[:columns].map { |c| c[:label] }).to eq(['Assigned To', 'Count', 'Total Selling Price', 'Average Selling Price'])
    expect(out[:rows].first).to eq('owner_id' => 'Ana Rep', 'count' => 2, 'sum_selling_price' => 150_000.0, 'avg_selling_price' => 75_000.0)
    expect(out[:rows].last['owner_id']).to eq('Bo Rep')
    expect(out[:meta]).to include(grouped: true, total: 2)
    expect(out[:columns].first[:type]).to eq('string')
  end

  it 'totals a group with no prices as 0' do
    company.deals.create!(name: 'No price', contact_id: buyer.id, owner_id: bo.id, stage: 'closed_won', actual_close_date: Date.parse('2026-10-01'))
    company.deals.where(owner_id: bo.id).where.not(name: 'No price').delete_all
    out = run(group_by: 'owner_id', aggregates: [{ fn: 'sum', field: 'selling_price' }])
    expect(out[:rows].find { |r| r['owner_id'] == 'Bo Rep' }['sum_selling_price']).to eq(0)
  end

  it 'groups a date by month, oldest first' do
    out = run(group_by: 'actual_close_date', group_period: 'month', aggregates: [{ fn: 'sum', field: 'selling_price' }])
    expect(out[:rows]).to eq([
      { 'actual_close_date' => '2026-09', 'sum_selling_price' => 100_000.0 },
      { 'actual_close_date' => '2026-10', 'sum_selling_price' => 130_000.0 }
    ])
    expect(out[:columns].first[:label]).to eq('Actual Close Date (month)')
    quarters = run(group_by: 'actual_close_date', group_period: 'quarter')[:rows].map { |r| r['actual_close_date'] }
    expect(quarters).to eq(%w[2026-Q3 2026-Q4])
  end

  it 'shows a month with nothing in it as 0, not skipped' do
    company.deals.create!(name: 'D Dec', contact_id: buyer.id, owner_id: bo.id, selling_price: 10_000,
                          stage: 'closed_won', actual_close_date: Date.parse('2026-12-02'))
    out = run(group_by: 'actual_close_date', group_period: 'month', aggregates: [{ fn: 'count' }, { fn: 'avg', field: 'selling_price' }])
    expect(out[:rows].map { |r| [r['actual_close_date'], r['count']] }).to eq([['2026-09', 1], ['2026-10', 2], ['2026-11', 0], ['2026-12', 1]])
    expect(out[:rows][2]['avg_selling_price']).to be_nil
    newest_first = run(group_by: 'actual_close_date', group_period: 'month', sort_by: 'actual_close_date', sort_order: 'desc')
    expect(newest_first[:rows].map { |r| r['actual_close_date'] }).to eq(%w[2026-12 2026-11 2026-10 2026-09])
    by_count = run(group_by: 'actual_close_date', group_period: 'month', sort_by: 'count')
    expect(by_count[:rows].size).to eq(3)
  end

  it 'counts by default and keeps filters' do
    out = run(group_by: 'owner_id', filters: { where: [{ field: 'selling_price', operator: 'gt', value: 60_000 }] })
    expect(out[:rows].map { |r| r['count'] }).to eq([1, 1])
  end

  it 'will not group by something different on every record' do
    expect { run(group_by: 'selling_price') }.to raise_error(ArgumentError, /different on every record/)
    expect { run(group_by: 'id') }.to raise_error(ArgumentError, /different on every record/)
    groupable = described_class.field_definitions('deals').select { |f| f[:groupable] }.map { |f| f[:key].to_s }
    expect(groupable).to include('stage', 'owner_id', 'actual_close_date')
    expect(groupable).not_to include('id', 'deal_number', 'name', 'selling_price', 'probability')
  end

  it 'refuses fields, functions and periods it does not know' do
    expect { run(group_by: 'name; DROP TABLE deals') }.to raise_error(ArgumentError, /Cannot group by/)
    expect { run(group_by: 'owner_id', aggregates: [{ fn: 'sum', field: 'selling_price) FROM users --' }]) }.to raise_error(ArgumentError, /Cannot total/)
    expect { run(group_by: 'owner_id', aggregates: [{ fn: 'pg_sleep', field: 'selling_price' }]) }.to raise_error(ArgumentError, /Unknown total/)
    expect { run(group_by: 'actual_close_date', group_period: "month', now()) --") }.to raise_error(ArgumentError, /Unknown period/)
    expect { run(group_by: 'stage', group_period: 'month') }.to raise_error(ArgumentError, /Only a date field/)
    expect { run(group_by: 'owner_id', aggregates: [{ fn: 'sum', field: 'name' }]) }.to raise_error(ArgumentError, /number fields/)
  end

  it 'never puts an unknown custom field key into the SQL' do
    out = run(fields: ['name', "cf_x' , (SELECT 1) AS y --"])
    expect(out[:columns].map { |c| c[:key] }).not_to include(a_string_starting_with('cf_'))
  end

  it 'still reads a real custom field' do
    CustomField.create!(company: company, module: 'deals', name: 'Lot', label: 'Lot', field_key: 'lot', field_type: 'text', is_active: true)
    out = run(fields: %w[name cf_lot])
    expect(out[:columns].map { |c| c[:key] }).to include('cf_lot')
  end
end
