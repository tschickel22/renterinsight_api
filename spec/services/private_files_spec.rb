# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/private_files_stub')

RSpec.describe PrivateFiles do
  let!(:client) { stub_private_files }

  describe '.locate' do
    it 'reads references, both S3 URL styles, presigned URLs and bare legacy keys' do
      expect(described_class.locate('s3://dt-private-test/bills/4/11/a.pdf')).to eq(['dt-private-test', 'bills/4/11/a.pdf'])
      expect(described_class.locate('https://legacy-public-test.s3.us-west-2.amazonaws.com/agreements/15/documents/x%20y.pdf'))
        .to eq(['legacy-public-test', 'agreements/15/documents/x y.pdf'])
      expect(described_class.locate('https://s3.us-west-2.amazonaws.com/legacy-public-test/imports/3/f.csv'))
        .to eq(['legacy-public-test', 'imports/3/f.csv'])
      expect(described_class.locate('https://dt-private-test.s3.us-west-2.amazonaws.com/bills/4/a.pdf?X-Amz-Signature=abc'))
        .to eq(['dt-private-test', 'bills/4/a.pdf'])
      expect(described_class.locate('imports/3/f.csv')).to eq(['legacy-public-test', 'imports/3/f.csv'])
    end

    it 'ignores anything that is not one of our files' do
      ['', nil, 'data:image/png;base64,AAAA', 'about:blank', 'John Smith', 'https://example.com/a.pdf',
       'https://someone-else.s3.amazonaws.com/a.pdf', 's3://someone-else/a.pdf'].each do |v|
        expect(described_class.locate(v)).to be_nil, "expected #{v.inspect} to be ignored"
      end
    end
  end

  describe '.normalize' do
    it 'stores a reference for a presigned or legacy URL, and leaves other values alone' do
      expect(described_class.normalize('https://dt-private-test.s3.us-west-2.amazonaws.com/bills/4/a.pdf?X-Amz-Expires=3600'))
        .to eq('s3://dt-private-test/bills/4/a.pdf')
      expect(described_class.normalize('https://legacy-public-test.s3.us-west-2.amazonaws.com/agreements/1/a.pdf'))
        .to eq('s3://legacy-public-test/agreements/1/a.pdf')
      expect(described_class.normalize('data:image/png;base64,AAAA')).to eq('data:image/png;base64,AAAA')
    end
  end

  describe '.url' do
    it 'presigns our files and passes everything else through' do
      url = described_class.url('s3://dt-private-test/bills/4/a.pdf', expires_in: 5.minutes, filename: 'Bill "4".pdf')
      expect(url).to start_with('https://dt-private-test.s3.us-west-2.amazonaws.com/bills/4/a.pdf?')
      expect(url).to include('X-Amz-Signature=', 'X-Amz-Expires=300', 'response-content-disposition=inline')
      expect(url).not_to include('%22%224')

      expect(described_class.url('data:image/png;base64,AAAA')).to eq('data:image/png;base64,AAAA')
      expect(described_class.url('https://example.com/a.pdf')).to eq('https://example.com/a.pdf')
      expect(described_class.url('s3://someone-else/a.pdf')).to be_nil
    end
  end

  describe '.read' do
    it 'fetches only files we stored, so a client URL cannot reach an arbitrary address' do
      expect { described_class.read('http://169.254.169.254/latest/meta-data/') }.to raise_error(described_class::Forbidden)
      expect { described_class.read('https://example.com/a.pdf') }.to raise_error(described_class::Forbidden)
    end

    it 'refuses another company’s file when asked to check' do
      client.stub_responses(:get_object, { body: 'PDF' })
      expect(described_class.read('s3://dt-private-test/agreements/7/a.pdf', company_id: 7)).to eq('PDF')
      expect { described_class.read('s3://dt-private-test/agreements/7/a.pdf', company_id: 8) }
        .to raise_error(described_class::Forbidden)
    end

    it 'decodes data URIs without touching S3' do
      expect(described_class.read("data:image/png;base64,#{Base64.strict_encode64('png!')}")).to eq('png!')
    end
  end

  describe '.owned_by?' do
    it 'reads the company from the folder' do
      expect(described_class.owned_by?('s3://dt-private-test/bills/4/11/a.pdf', 4)).to be(true)
      expect(described_class.owned_by?('s3://dt-private-test/bills/44/11/a.pdf', 4)).to be(false)
      expect(described_class.owned_by?('s3://dt-private-test/site-profiles/uploads/9/a.pdf', 9)).to be(true)
      expect(described_class.owned_by?('https://example.com/bills/4/a.pdf', 4)).to be(false)
    end
  end

  describe '.durable_url' do
    it 'round-trips a reference and rejects a tampered token' do
      link = described_class.durable_url('s3://dt-private-test/custom-fields/3/leads/1/a.pdf')
      token = link.split('/pf/').last
      expect(token).to match(/\A[A-Za-z0-9_=-]+(--[A-Za-z0-9_=-]+)?\z/)
      expect(described_class.from_durable_token(token)).to eq('s3://dt-private-test/custom-fields/3/leads/1/a.pdf')
      expect(described_class.from_durable_token("#{token}x")).to be_nil
    end
  end

  describe '.put and .upload' do
    it 'writes to the private bucket and returns a reference' do
      expect(described_class.put('bytes', key: 'agreements/1/sealed/a.pdf', content_type: 'application/pdf'))
        .to eq('s3://dt-private-test/agreements/1/sealed/a.pdf')
      expect(client.api_requests.last[:params]).to include(bucket: 'dt-private-test', key: 'agreements/1/sealed/a.pdf')
    end

    it 'refuses to run without a private bucket' do
      stub_const('ENV', ENV.to_h.merge('PRIVATE_DOCUMENTS_BUCKET' => ''))
      expect { described_class.put('x', key: 'bills/1/a') }.to raise_error(described_class::NotConfigured)
    end
  end

  describe '.copy_to_private' do
    it 'copies a legacy object under the same key' do
      ref = described_class.copy_to_private('https://legacy-public-test.s3.us-west-2.amazonaws.com/bills/4/a b.pdf')
      expect(ref).to eq('s3://dt-private-test/bills/4/a b.pdf')
      expect(client.api_requests.last[:params]).to include(bucket: 'dt-private-test', key: 'bills/4/a b.pdf',
                                                           copy_source: 'legacy-public-test/bills/4/a%20b.pdf')
    end
  end
end
