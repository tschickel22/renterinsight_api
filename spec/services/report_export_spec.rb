# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ReportExport do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "exp-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Ex', last_name: 'Port', status: 'active')
  end

  def engine_result(rows:, total:)
    {
      columns: [{ key: 'name', label: 'Name, full', type: 'string' }, { key: 'note', label: 'Note', type: 'string' },
                { key: 'amount', label: 'Amount', type: 'number' }],
      rows: rows, meta: { total: total, page: 1, per_page: 500, total_pages: 1 }
    }
  end

  let(:rows) do
    [{ 'name' => '=HYPERLINK("http://x")', 'note' => "line one\nline two", 'amount' => '-500' },
     { 'name' => 'Plain', 'note' => '@home', 'amount' => 12.5 }]
  end

  before { allow(ReportEngine).to receive(:run).and_return(engine_result(rows: rows, total: rows.size)) }

  def call
    described_class.call(company: company, user: user, location_id: nil, name: 'My Leads', ip: '1.2.3.4',
                         query: { module: 'leads', fields: %w[name note amount] })
  end

  it 'writes a CSV a spreadsheet reads safely' do
    parsed = CSV.parse(call.csv)
    expect(parsed[0]).to eq(['Name, full', 'Note', 'Amount', 'export_ref'])
    expect(parsed[1][0]).to eq(%('=HYPERLINK("http://x")))
    expect(parsed[1][1]).to eq("line one\nline two")
    expect(parsed[1][2]).to eq('-500')
    expect(parsed[2][1]).to eq("'@home")
    expect(parsed.size).to eq(3)
  end

  it 'records the export with its watermark on every row' do
    export = nil
    expect { export = call }.to change(ExportJob, :count).by(1)
    job = ExportJob.last
    expect(job.row_count).to eq(2)
    expect(job.module_type).to eq('report:leads')
    expect(CSV.parse(export.csv)[1].last).to eq(job.watermark_token)
    expect(export.filename).to start_with('my-leads-')
  end

  it 'says when the file was cut at the row cap' do
    allow(ReportEngine).to receive(:run).and_return(engine_result(rows: rows, total: 3_000))
    export = call
    expect(export.truncated?).to be(true)
    expect(export.total).to eq(3_000)
    expect(ExportJob.last.filters['export_scope']).to eq('first_page')
  end
end
