#!/bin/bash
# Complete Rails Server Check

echo "============================================"
echo "🔍 RAILS SERVER DIAGNOSTIC"
echo "============================================"

echo ""
echo "1️⃣ Checking if Rails is running..."
RAILS_PID=$(ps aux | grep "rails s" | grep -v grep | awk '{print $2}')

if [ -z "$RAILS_PID" ]; then
  echo "   ❌ Rails server is NOT running"
  echo ""
  echo "   To start Rails on port 3001 with HTTPS:"
  echo "   cd ~/src/renterinsight_api"
  echo "   rails s -p 3001 -b ssl://localhost:3001?key=localhost+1-key.pem&cert=localhost+1.pem"
  echo ""
  echo "   OR simpler (HTTP for now):"
  echo "   rails s -p 3001"
  exit 1
else
  echo "   ✅ Rails is running (PID: $RAILS_PID)"
fi

echo ""
echo "2️⃣ Checking what port Rails is on..."
PORT=$(lsof -i -P -n | grep LISTEN | grep ruby | grep -o ':\d\+' | head -1 | tr -d ':')

if [ -z "$PORT" ]; then
  echo "   ❌ Cannot determine Rails port"
else
  echo "   Port: $PORT"
  if [ "$PORT" != "3001" ]; then
    echo "   ⚠️  WARNING: Rails is on port $PORT, but frontend expects 3001!"
    echo "   Restart Rails on port 3001:"
    echo "   rails s -p 3001"
  else
    echo "   ✅ Rails is on correct port (3001)"
  fi
fi

echo ""
echo "3️⃣ Testing invitation endpoint..."
cd ~/src/renterinsight_api

# Test the route
echo "   Testing: curl -k https://localhost:3001/api/public/invitations/verify?token=test"
RESPONSE=$(curl -k -s -w "\n%{http_code}" "https://localhost:3001/api/public/invitations/verify?token=test" 2>&1)
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "404" ]; then
  echo "   ❌ 404 Not Found - Route doesn't exist!"
  echo ""
  echo "   Checking routes..."
  bundle exec rails routes | grep "public/invitations" || echo "   No public invitation routes found!"
elif [ "$HTTP_CODE" = "000" ]; then
  echo "   ❌ Cannot connect to server"
  echo "   Response: $RESPONSE"
else
  echo "   ✅ Endpoint responding (HTTP $HTTP_CODE)"
  echo "   Response: $BODY"
fi

echo ""
echo "============================================"
echo "💡 SUMMARY"
echo "============================================"

if [ -z "$RAILS_PID" ]; then
  echo "❌ Rails is not running - START IT"
elif [ "$PORT" != "3001" ]; then
  echo "❌ Rails on wrong port - RESTART on 3001"
elif [ "$HTTP_CODE" = "404" ]; then
  echo "❌ Route missing - CHECK routes.rb"
else
  echo "✅ Server looks good - try invitation again!"
fi

echo ""
