# frozen_string_literal: true

require 'rails_helper'

# Regression: a failed ad-account sync rendered Facebook's entire HTML error
# page inside the toast, and a failed ad launch rendered Meta's bare "Invalid
# parameter" with no indication of which field was wrong.
RSpec.describe MetaGraphApi, '.handle_response' do
  def respond(code, body)
    instance_double(Net::HTTPResponse, code: code.to_s, body: body)
  end

  def handle(code, body)
    described_class.send(:handle_response, respond(code, body))
  end

  it 'returns the parsed body on success' do
    expect(handle(200, '{"data":[{"id":"1"}]}')).to eq('data' => [{ 'id' => '1' }])
  end

  it 'does not leak an HTML error page into the message' do
    html = '<!DOCTYPE html><html><head><title>Facebook | Error</title></head>' \
           '<body><h1 id="sorry">Sorry, something went wrong.</h1></body></html>'

    expect { handle(400, html) }.to raise_error(MetaGraphApi::Error) do |e|
      expect(e.message).not_to include('<')
      expect(e.message).not_to include('Sorry, something went wrong')
      expect(e.message).to match(/unreadable/i)
    end
  end

  it 'surfaces error_user_msg over the generic message' do
    body = {
      error: {
        code: 100,
        message: 'Invalid parameter',
        error_user_title: 'Ad set budget too low',
        error_user_msg: 'The daily budget must be at least $5.00.'
      }
    }.to_json

    expect { handle(400, body) }.to raise_error(
      MetaGraphApi::Error, /Ad set budget too low — The daily budget must be at least \$5\.00\./
    )
  end

  # Meta sends error_data as a Hash on some errors and a JSON string on others.
  # Assuming one shape made the error handler itself raise, turning a readable
  # rejection into a 500 and a useless "Unable to launch ad".
  it 'reads blame fields when error_data arrives as a JSON string' do
    body = {
      error: {
        code: 100,
        message: 'Invalid parameter',
        error_user_title: 'Special Ad Category Errors',
        error_data: { blame_field_specs: [['Custom age selection is unavailable']] }.to_json
      }
    }.to_json

    expect { handle(400, body) }.to raise_error(
      MetaGraphApi::Error, /Field: Custom age selection is unavailable/
    )
  end

  it 'survives error_data that is a string but not JSON' do
    body = { error: { code: 100, message: 'Invalid parameter', error_data: 'nonsense' } }.to_json

    expect { handle(400, body) }.to raise_error(MetaGraphApi::Error, /Invalid parameter/)
  end

  it 'names the field Meta blamed' do
    body = {
      error: {
        code: 100,
        message: 'Invalid parameter',
        error_data: { blame_field_specs: [['targeting', 'age_min']] }
      }
    }.to_json

    expect { handle(400, body) }.to raise_error(MetaGraphApi::Error, /Field: targeting, age_min/)
  end

  it 'falls back to the plain message when Meta offers nothing better' do
    body = { error: { code: 100, message: 'Invalid parameter' } }.to_json

    expect { handle(400, body) }.to raise_error(MetaGraphApi::Error, /\(100\): Invalid parameter/)
  end

  it 'still classifies an expired token' do
    body = { error: { code: 190, message: 'Session has expired' } }.to_json

    expect { handle(400, body) }.to raise_error(MetaGraphApi::ExpiredTokenError)
  end

  it 'does not dump the raw body on a 5xx either' do
    expect { handle(500, '<html><body>internal</body></html>') }
      .to raise_error(MetaGraphApi::Error) { |e| expect(e.message).not_to include('<html>') }
  end
end
