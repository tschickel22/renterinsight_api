# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/private_files_stub')

RSpec.describe PrivateFileColumns do
  before { stub_private_files }

  let(:company) { Company.create!(name: "Co #{SecureRandom.hex(3)}") }
  let(:vehicle) { company.vehicles.create!(make: 'Champion', model: 'Aspire', year: 2026, serial_number: "S#{SecureRandom.hex(4)}",
                                                  vin: "VIN#{SecureRandom.hex(6)}") }

  it 'stores a reference when the browser sends back a presigned URL, and presigns on the way out' do
    presigned = 'https://dt-private-test.s3.us-west-2.amazonaws.com/vehicles/1/2/documents/inv.pdf?X-Amz-Signature=old'
    doc = VehicleDocument.create!(vehicle: vehicle, title: 'Invoice', category: 'other',
                                  visibility: 'internal', file_url: presigned)

    expect(doc.reload.file_url).to eq('s3://dt-private-test/vehicles/1/2/documents/inv.pdf')
    expect(doc.as_json['file_url']).to include('X-Amz-Signature=').and(start_with('https://dt-private-test.s3.'))
    expect(doc.file_url_link).to include('X-Amz-Signature=')
  end

  it 'normalizes attachment hashes and lists' do
    log = AssignmentWorkLog.new(attachments: [{ url: 'https://legacy-public-test.s3.us-west-2.amazonaws.com/contractor-work-logs/1/2/a.jpg',
                                                s3_key: 'contractor-work-logs/1/2/a.jpg', filename: 'a.jpg' }])
    log.run_callbacks(:save) { true }
    expect(log.attachments.first['url']).to eq('s3://legacy-public-test/contractor-work-logs/1/2/a.jpg')
    expect(log.attachments_links.first['url']).to include('X-Amz-Signature=')
  end
end
