#!/usr/bin/env ruby
# frozen_string_literal: true
# Create test documents for buyer portal testing

puts "🔧 Phase 4C - Creating test documents..."
puts ""

# Find the test buyer from Phase 4A/4B
lead = Lead.find_by(email: 'testbuyer@example.com')

if lead.nil?
  puts "❌ Test buyer not found. Please run Phase 4A/4B setup first."
  puts ""
  puts "Run this first:"
  puts "  cd ~/src/renterinsight_api"
  puts "  bin/rails runner create_test_buyer.rb"
  exit 1
end

account = Account.find_by(id: lead.converted_account_id)

if account.nil?
  puts "❌ Test account not found. Please run Phase 4B setup first."
  exit 1
end

puts "✅ Found buyer: #{lead.first_name} #{lead.last_name} (#{lead.email})"
puts "✅ Account: #{account.name} (ID: #{account.id})"
puts ""

# Find or create a quote to relate documents to
quote = Quote.where(account: account).first

if quote.nil?
  quote = Quote.create!(
    account: account,
    quote_number: "Q-#{Time.current.year}-#{Account.count.to_s.rjust(3, '0')}",
    status: 'sent',
    subtotal: 5000.00,
    tax: 500.00,
    total: 5500.00,
    items: [
      {
        'description' => 'Equipment Rental',
        'quantity' => 1,
        'unit_price' => 5000.00,
        'total' => 5000.00
      }
    ],
    valid_until: 30.days.from_now.to_date
  )
  puts "✅ Created test quote: #{quote.quote_number}"
end

# Clean up old test documents
PortalDocument.where(owner: lead).destroy_all
puts "🗑️  Cleaned up old test documents"
puts ""

# Create sample documents
documents = [
  {
    filename: 'insurance_card_2024.pdf',
    category: 'insurance',
    description: 'Current insurance card valid through 2024',
    related_to: nil
  },
  {
    filename: 'drivers_license.pdf',
    category: 'registration',
    description: 'Driver\'s license copy',
    related_to: nil
  },
  {
    filename: 'quote_acceptance.pdf',
    category: 'invoice',
    description: 'Signed quote acceptance',
    related_to: quote
  }
]

puts "📄 Creating test documents..."
puts ""

documents.each do |doc_info|
  # Create document without saving yet
  doc = PortalDocument.new(
    owner: lead,
    category: doc_info[:category],
    description: doc_info[:description],
    related_to: doc_info[:related_to],
    uploaded_by: 'buyer',
    uploaded_at: rand(1..10).days.ago
  )
  
  # Create a simple test PDF content
  pdf_content = "%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /MediaBox [0 0 612 792] /Contents 4 0 R >>
endobj
4 0 obj
<< /Length 80 >>
stream
BT
/F1 12 Tf
100 700 Td
(#{doc_info[:filename]}) Tj
100 680 Td
(Test Document) Tj
ET
endstream
endobj
xref
0 5
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000309 00000 n 
trailer
<< /Size 5 /Root 1 0 R >>
startxref
407
%%EOF"
  
  # Create a temp file
  require 'tempfile'
  temp_file = Tempfile.new(['test', '.pdf'])
  temp_file.write(pdf_content)
  temp_file.rewind
  
  # Attach the file
  doc.file.attach(
    io: temp_file,
    filename: doc_info[:filename],
    content_type: 'application/pdf'
  )
  
  # Now save with the file attached
  doc.save!
  
  temp_file.close
  temp_file.unlink
  
  related_info = doc.related_to ? " (related to #{doc.related_to.quote_number})" : ""
  puts "  ✅ #{doc_info[:filename]} - #{doc_info[:category]}#{related_info}"
end

puts ""
puts "✅ Created #{PortalDocument.count} test documents"
puts ""

# Get auth token for testing
buyer_access = BuyerPortalAccess.find_by(buyer: lead)
token = JsonWebToken.encode(buyer_portal_access_id: buyer_access.id)

puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts "📋 TEST ENDPOINTS"
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts ""
puts "🔑 Auth Token (saved to TOKEN env var):"
puts "   #{token[0..50]}..."
puts ""
puts "💡 Copy/paste these commands:"
puts ""
puts "# Save token to environment variable"
puts "export TOKEN='#{token}'"
puts ""
puts "# 1. List all documents"
puts 'curl -X GET http://localhost:3001/api/portal/documents \\'
puts '  -H "Authorization: Bearer $TOKEN" | jq'
puts ""
puts "# 2. List documents by category"
puts 'curl -X GET "http://localhost:3001/api/portal/documents?category=insurance" \\'
puts '  -H "Authorization: Bearer $TOKEN" | jq'
puts ""
puts "# 3. Get document details"
first_doc = PortalDocument.where(owner: lead).first
if first_doc
  puts "curl -X GET http://localhost:3001/api/portal/documents/#{first_doc.id} \\"
  puts '  -H "Authorization: Bearer $TOKEN" | jq'
  puts ""
  puts "# 4. Download document"
  puts "curl -X GET http://localhost:3001/api/portal/documents/#{first_doc.id}/download \\"
  puts '  -H "Authorization: Bearer $TOKEN" -o downloaded_file.pdf'
  puts ""
end
puts "# 5. Upload a new document"
puts 'curl -X POST http://localhost:3001/api/portal/documents \\'
puts '  -H "Authorization: Bearer $TOKEN" \\'
puts '  -F "file=@/path/to/your/file.pdf" \\'
puts '  -F "category=insurance" \\'
puts '  -F "description=My new document" | jq'
puts ""
if first_doc
  puts "# 6. Delete a document"
  puts "curl -X DELETE http://localhost:3001/api/portal/documents/#{first_doc.id} \\"
  puts '  -H "Authorization: Bearer $TOKEN" | jq'
  puts ""
end
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts ""
puts "✅ Phase 4C test data ready!"
puts "   Run the curl commands above to test the endpoints"
puts ""
