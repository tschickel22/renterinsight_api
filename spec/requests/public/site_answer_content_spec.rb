# frozen_string_literal: true

require 'rails_helper'

# The content AI assistants quote: FAQs, what customers said, the numbers.
# Before, the server copy dropped FAQ questions, every testimonial and every
# stat, and marked none of it up.
RSpec.describe 'Public::Sites answerable content', type: :request do
  let(:company)  { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:location) { company.locations.create!(name: 'Showroom') }
  let(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Sunshine RV',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'published', brand: { 'company_name' => 'Sunshine RV' })
  end
  let!(:about) do
    website.website_pages.create!(title: 'About', path: '/about', order: 1, blocks: [
      { 'type' => 'faq', 'order' => 0, 'content' => { 'title' => 'Questions', 'faqs' => [
        { 'question' => 'Do you offer financing?', 'answer' => 'Yes, with several lenders.' },
        { 'question' => 'Empty answer?', 'answer' => '' }
      ] } },
      { 'type' => 'testimonials', 'order' => 1, 'content' => { 'title' => 'Reviews', 'testimonials' => [
        { 'quote' => 'They made it easy.', 'author' => 'Dana R.', 'role' => 'Homeowner' }
      ] } },
      { 'type' => 'stats', 'order' => 2, 'content' => { 'stats' => [{ 'number' => '25+', 'label' => 'Years serving Denver' }] } },
      { 'type' => 'image', 'order' => 3, 'content' => { 'src' => 'https://img.example.com/lot.jpg', 'alt' => 'Our lot at sunset' } }
    ])
  end
  let!(:domain) do
    company.company_domains.create!(hostname: 'sunshine-rv.test', website_id: website.id, verification_status: 'active')
  end

  before do
    Rails.cache.clear
    allow(Websites::SpaShell).to receive(:fetch) do
      Websites::SpaShell.absolutize('<!doctype html><html><head><title>App</title></head><body><div id="root"></div></body></html>',
                                    'https://spa.example.com')
    end
    get '/about', headers: { 'HTTP_HOST' => 'sunshine-rv.test' }
  end

  let(:body) { response.body[%r{<div id="dt-prerender">(.*)</div>}m, 1] }

  it 'sends FAQ questions with their answers' do
    expect(body).to include('<h3>Do you offer financing?</h3>', 'Yes, with several lenders.')
  end

  it 'marks FAQs up, leaving out questions with no answer' do
    graph = JSON.parse(response.body[%r{<script type="application/ld\+json">(.*?)</script>}m, 1])['@graph']
    faq = graph.detect { |n| n['@type'] == 'FAQPage' }

    expect(faq['mainEntity'].map { |q| q['name'] }).to eq(['Do you offer financing?'])
    expect(faq['mainEntity'].first['acceptedAnswer']['text']).to eq('Yes, with several lenders.')
  end

  it 'sends testimonials, stats and image-block pictures' do
    expect(body).to include('<blockquote><p>They made it easy.</p><footer>Dana R., Homeowner</footer></blockquote>')
    expect(body).to include('<strong>25+</strong> Years serving Denver')
    expect(body).to include('src="https://img.example.com/lot.jpg" alt="Our lot at sunset"')
  end
end
