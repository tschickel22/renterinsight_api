# frozen_string_literal: true

# PrivateFiles talks to S3. In specs it gets a stubbed client (no network) and
# fixed bucket names, set per example with `stub_private_files`.
module PrivateFilesStub
  def stub_private_files(private_bucket: 'dt-private-test', legacy_bucket: 'legacy-public-test')
    stub_const('ENV', ENV.to_h.merge('PRIVATE_DOCUMENTS_BUCKET' => private_bucket, 'AWS_S3_BUCKET' => legacy_bucket,
                                     'AWS_REGION' => 'us-west-2'))
    client = Aws::S3::Client.new(stub_responses: true, region: 'us-west-2',
                                 credentials: Aws::Credentials.new('AKIDTEST', 'secret'))
    PrivateFiles.instance_variable_set(:@client, client)
    client
  end
end

RSpec.configure do |config|
  config.include PrivateFilesStub
  config.after { PrivateFiles.instance_variable_set(:@client, nil) }
end
