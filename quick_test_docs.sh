#!/bin/bash

echo "Testing Document Upload Enhancement..."
echo ""

cd ~/src/renterinsight_api

echo "1. Checking if columns exist..."
bundle exec rails runner "
columns = PortalDocument.column_names
puts '✓ document_name exists' if columns.include?('document_name')
puts '✓ notes exists' if columns.include?('notes')
puts '✗ Missing columns!' unless columns.include?('document_name') && columns.include?('notes')
"

echo ""
echo "2. Testing DocumentPresenter..."
bundle exec rails runner "
begin
  require_relative 'lib/document_presenter'
  puts '✓ DocumentPresenter loaded successfully'
  
  # Test with sample data
  doc = PortalDocument.new(
    document_name: 'Test Doc',
    notes: 'Test notes',
    category: 'insurance',
    uploaded_by: 'buyer',
    uploaded_at: Time.now
  )
  
  result = DocumentPresenter.list_json(doc)
  puts '✓ DocumentPresenter.list_json works'
  puts '✓ Returns document_name:' + result[:document_name].to_s
  puts '✓ Returns notes: ' + result[:notes].to_s
rescue => e
  puts '✗ Error: ' + e.message
  puts e.backtrace.first(5).join(\"\n\")
end
"

echo ""
echo "3. Restart your Rails server now:"
echo "   bundle exec rails server"
echo ""
echo "4. Then test the upload from the frontend!"
