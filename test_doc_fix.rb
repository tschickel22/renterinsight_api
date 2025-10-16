buyer = BuyerPortalAccess.find_by(email: 't+client@renterinsight.com')

if buyer.nil?
  puts "❌ ERROR: Buyer not found with email: t+client@renterinsight.com"
  exit
end

puts "✅ Found buyer: #{buyer.email} (ID: #{buyer.id})"
puts "   Portal enabled: #{buyer.portal_enabled}"
puts "   Associated with: #{buyer.buyer_type} ##{buyer.buyer_id}"

docs = PortalDocument.where(owner_type: 'BuyerPortalAccess', owner_id: buyer.id)

puts "\n📄 Documents found: #{docs.count}"

if docs.any?
  docs.each_with_index do |doc, idx|
    puts "\n  Document #{idx + 1}:"
    puts "    ID: #{doc.id}"
    puts "    File: #{doc.file.attached? ? doc.file.filename : 'No file attached'}"
    puts "    Size: #{doc.file.attached? ? (doc.file.byte_size / 1024.0).round(2) : 0} KB"
    puts "    Category: #{doc.category}"
    puts "    Uploaded by: #{doc.uploaded_by}"
    puts "    Uploaded at: #{doc.uploaded_at}"
    puts "    Owner: #{doc.owner_type} ##{doc.owner_id}"
  end
  puts "\n✅ SUCCESS: Documents are visible!"
else
  puts "\n⚠️  No documents found."
  puts "   Either:"
  puts "   1. No documents have been uploaded yet"
  puts "   2. Documents have wrong owner_type"
  
  # Check for old documents
  old_docs = PortalDocument.where(owner_type: buyer.buyer_type, owner_id: buyer.buyer_id)
  if old_docs.any?
    puts "\n⚠️  Found #{old_docs.count} document(s) with old owner_type!"
    puts "   To migrate them, run:"
    puts "   PortalDocument.where(owner_type: '#{buyer.buyer_type}', owner_id: #{buyer.buyer_id}).update_all(owner_type: 'BuyerPortalAccess', owner_id: #{buyer.id})"
  end
end
