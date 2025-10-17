#!/bin/bash
# Setup script for Vehicles/Inventory Integration

echo "🚗 Setting up Vehicles/Inventory Integration..."
echo ""

# Navigate to Rails directory
cd ~/src/renterinsight_api || exit 1

echo "✅ Step 1: Running migration..."
bin/rails db:migrate
if [ $? -ne 0 ]; then
  echo "❌ Migration failed!"
  exit 1
fi

echo ""
echo "✅ Step 2: Creating test vehicles..."
ruby create_test_vehicles.rb
if [ $? -ne 0 ]; then
  echo "❌ Failed to create test vehicles!"
  exit 1
fi

echo ""
echo "✅ Step 3: Testing vehicles API endpoint..."
echo "Testing: GET /api/v1/vehicles"

# Start Rails server in background if not already running
if ! pgrep -f "rails s" > /dev/null; then
  echo "Starting Rails server..."
  bin/rails s -p 3001 &
  SERVER_PID=$!
  sleep 5
  echo "Server started with PID: $SERVER_PID"
else
  echo "Rails server already running"
  SERVER_PID=""
fi

# Wait for server to be ready
echo "Waiting for server to be ready..."
for i in {1..30}; do
  if curl -s http://localhost:3001/api/v1/vehicles > /dev/null 2>&1; then
    echo "Server is ready!"
    break
  fi
  sleep 1
done

# Test the API
echo ""
echo "Testing API response..."
curl -s http://localhost:3001/api/v1/vehicles | head -c 500
echo ""

# Stop server if we started it
if [ -n "$SERVER_PID" ]; then
  echo ""
  echo "Stopping test server..."
  kill $SERVER_PID 2>/dev/null || true
fi

echo ""
echo "✅ Vehicle integration setup complete!"
echo ""
echo "📊 Summary:"
echo "  - Migration run successfully"
echo "  - Test vehicles created"
echo "  - API endpoints configured"
echo ""
echo "🎯 Next Steps:"
echo "  1. Start Rails server: bin/rails s -p 3001"
echo "  2. Start Frontend: npm run dev"
echo "  3. Navigate to: http://localhost:5173/quotes/new"
echo "  4. Test vehicle dropdown"
echo ""
echo "📝 API Endpoints Available:"
echo "  - GET    /api/v1/vehicles              - List all vehicles"
echo "  - GET    /api/v1/vehicles/:id          - Get single vehicle"
echo "  - POST   /api/v1/vehicles              - Create vehicle"
echo "  - PATCH  /api/v1/vehicles/:id          - Update vehicle"
echo "  - DELETE /api/v1/vehicles/:id          - Delete vehicle"
echo "  - GET    /api/v1/vehicles/stats        - Get statistics"
echo ""
