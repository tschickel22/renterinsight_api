# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::Trueview::GeminiBatch do
  def reply(code, body = {}, headers = {})
    instance_double(HTTParty::Response, code: code, parsed_response: body, body: body.is_a?(String) ? body : body.to_json, headers: headers)
  end

  around do |ex|
    old = ENV['GEMINI_API_KEY']
    ENV['GEMINI_API_KEY'] = 'test'
    ex.run
  ensure
    ENV['GEMINI_API_KEY'] = old
  end

  it 'uploads the requests as JSONL and creates the batch from the file' do
    posts = []
    allow(HTTParty).to receive(:post) do |url, **opts|
      posts << [url, opts]
      if url.end_with?('/files') then reply(200, {}, { 'x-goog-upload-url' => 'https://up/1' })
      elsif url == 'https://up/1' then reply(200, { 'file' => { 'name' => 'files/in1' } })
      else reply(200, { 'name' => 'batches/b1' })
      end
    end
    name = described_class.submit('gemini-lite', [['r1', { contents: [] }], ['r2', { contents: [] }]], display_name: 'run-1')
    expect(name).to eq('batches/b1')
    expect(posts[1].last[:body].lines.map { |l| JSON.parse(l)['key'] }).to eq(%w[r1 r2])
    expect(posts[2].first).to end_with('/models/gemini-lite:batchGenerateContent')
    expect(JSON.parse(posts[2].last[:body]).dig('batch', 'input_config', 'file_name')).to eq('files/in1')
  end

  it 'reads the state and the results file, keyed as sent' do
    allow(HTTParty).to receive(:get).with(%r{/batches/b1\z}, any_args)
                                    .and_return(reply(200, { 'metadata' => { 'state' => 'JOB_STATE_SUCCEEDED', 'output' => { 'responsesFile' => 'files/out' } } }))
    expect(described_class.status('batches/b1')).to include(done: true, failed: false, responses_file: 'files/out')

    lines = [{ key: 'r1', response: { 'candidates' => [] } }.to_json, { key: 'r2', error: { message: 'blocked' } }.to_json].join("\n")
    allow(HTTParty).to receive(:get).with(%r{files/out:download}, any_args).and_return(reply(200, lines))
    ok, bad = described_class.results('files/out')
    expect(ok.keys).to eq(['r1'])
    expect(bad).to eq('r2' => 'blocked')
  end
end
