#!/bin/bash

echo "==================================="
echo "Document Upload Enhancement Test"
echo "==================================="
echo ""

cd ~/src/renterinsight_api

echo "Step 1: Running migration..."
bundle exec rails db:migrate
echo ""

echo "Step 2: Verifying columns..."
bundle exec rails runner "puts 'Columns: ' + PortalDocument.column_names.select { |c| c.include?('name') || c == 'notes' }.join(', ')"
echo ""

echo "Step 3: Testing DocumentPresenter..."
bundle exec rails runner "
doc = PortalDocument.new(
  document_name: 'Test Document',
  notes: 'Test notes',
  category: 'insurance',
  uploaded_by: 'buyer'
)
puts 'DocumentPresenter loaded: ' + (defined?(DocumentPresenter) ? 'YES' : 'NO')
"
echo ""

echo "==================================="
echo "✅ Setup Complete!"
echo "==================================="
echo ""
echo "Next steps:"
echo "1. Start your Rails server: bundle exec rails server"
echo "2. Test the frontend upload form"
echo ""
