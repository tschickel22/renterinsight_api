# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Dns::PreFlight do
  let(:ours) { 'origin.mydealertide.com' }

  # Any name not stubbed answers nothing, which is what an unpublished name does.
  def stub_dns(cname: {}, a: {}, caa: {}, ns: {}, ttl: nil)
    allow(Dns::Lookup).to receive(:cname) { |n| Array(cname[n]) }
    allow(Dns::Lookup).to receive(:a) { |n| Array(a[n]) }
    allow(Dns::Lookup).to receive(:ns) { |n| Array(ns[n]) }
    allow(Dns::Lookup).to receive(:caa) do |n|
      Array(caa[n]).map { |v| { flags: 0, tag: 'issue', value: v } }
    end
    allow(Dns::Lookup).to receive(:authoritative_ttl).and_return(ttl)
  end

  # The case this was written for, as it stood on 2026-10-20 before anything changed.
  context 'with a www CNAME to Vercel held for a week' do
    before do
      stub_dns(
        cname: { 'www.easyhomesource.com' => 'cname.vercel-dns.com.' },
        a: { 'www.easyhomesource.com' => %w[76.76.21.93], ours => %w[104.21.3.90] },
        caa: { 'www.easyhomesource.com' => %w[letsencrypt.org pki.goog sectigo.com globalsign.com] },
        ns: { 'easyhomesource.com' => %w[ns59.domaincontrol.com] },
        ttl: 604_800
      )
    end

    let(:result) { described_class.for('www.easyhomesource.com', our_target: ours) }

    it 'sees the site is live elsewhere and picks TXT validation' do
      expect(result.live_elsewhere?).to be true
      expect(result.ssl_method).to eq('txt')
    end

    it 'reads CAA through the CNAME, as the CA does' do
      expect(result.caa_source).to eq('cname.vercel-dns.com')
      expect(result.caa_missing).to eq(%w[ssl.com])
    end

    it 'names all three problems' do
      expect(result.issues.map(&:key)).to eq(%w[live_elsewhere long_ttl caa_blocked])
    end

    it 'says the CAA fix needs the CNAME replaced, since a CAA cannot sit beside it' do
      detail = result.issues.find { |i| i.key == 'caa_blocked' }.detail
      expect(detail).to include('replace the CNAME with an A record to 76.76.21.93')
      expect(detail).to include('0 issue "ssl.com"')
    end

    it 'gives the TTL in words' do
      expect(result.issues.find { |i| i.key == 'long_ttl' }.detail).to include('7 days')
    end

    it 'writes no dashes into tenant-facing copy' do
      expect(result.issues.flat_map { |i| [i.headline, i.detail] }.join).not_to match(/[–—]/)
    end
  end

  it 'raises nothing when the hostname already points at us' do
    stub_dns(cname: { 'www.done.example' => "#{ours}." }, ns: { 'done.example' => %w[ns1.x] }, ttl: 86_400)

    result = described_class.for('www.done.example', our_target: ours)

    expect(result.points_at_us).to be true
    expect(result.ssl_method).to eq('http')
    expect(result.issues).to be_empty
  end

  it 'treats an unpublished hostname as nothing to protect' do
    stub_dns

    result = described_class.for('www.new.example', our_target: ours)

    expect(result.live_elsewhere?).to be false
    expect(result.ssl_method).to eq('http')
    expect(result.issues).to be_empty
  end

  it 'climbs to the parent for CAA and accepts a set that allows all three' do
    stub_dns(a: { 'www.ok.example' => %w[1.2.3.4] },
             caa: { 'ok.example' => %w[letsencrypt.org pki.goog ssl.com] })

    result = described_class.for('www.ok.example', our_target: ours)

    expect(result.caa_source).to eq('ok.example')
    expect(result.caa_missing).to be_empty
    expect(result.issues.map(&:key)).not_to include('caa_blocked')
  end

  it 'reads an issuer with parameters by its domain alone' do
    stub_dns(a: { 'www.p.example' => %w[1.2.3.4] },
             caa: { 'www.p.example' => ['letsencrypt.org; accounturi=x', 'pki.goog', 'ssl.com'] })

    expect(described_class.for('www.p.example', our_target: ours).caa_missing).to be_empty
  end
end
