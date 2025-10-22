#!/bin/bash
# Restart Rails server and test image uploads

echo "=========================================="
echo "RESTARTING RAILS SERVER"
echo "=========================================="

cd /home/tschi/src/renterinsight_api

# Kill any existing Rails server
pkill -f "rails s" 2>/dev/null
sleep 2

# Start Rails server
echo "Starting Rails server on port 3001..."
nohup bin/rails s -p 3001 > log/server.log 2>&1 &

sleep 3

# Check if server started
if pgrep -f "rails s" > /dev/null; then
    echo "✅ Rails server is running!"
    echo ""
    echo "Server PID: $(pgrep -f 'rails s')"
    echo "Log file: log/server.log"
    echo ""
    echo "=========================================="
    echo "IMAGE UPLOAD DIRECTORY STATUS"
    echo "=========================================="
    
    # Check uploads directory
    if [ -d "public/uploads/vehicles" ]; then
        echo "✅ Uploads directory exists"
        echo ""
        echo "Vehicle directories:"
        ls -la public/uploads/vehicles/ | tail -10
        echo ""
        echo "Total image count:"
        find public/uploads/vehicles -type f | wc -l
    else
        echo "❌ Uploads directory not found!"
        echo "Creating directory..."
        mkdir -p public/uploads/vehicles
        chmod -R 755 public/uploads
    fi
    
    echo ""
    echo "=========================================="
    echo "TESTING IMAGE UPLOAD ENDPOINT"
    echo "=========================================="
    
    # Test that the routes are loaded
    echo "Checking if image upload route exists..."
    bin/rails routes | grep "vehicle.*images"
    
else
    echo "❌ Failed to start Rails server"
    echo "Check log/server.log for errors"
    tail -20 log/server.log
fi

echo ""
echo "=========================================="
echo "Server is ready at: http://localhost:3001"
echo "=========================================="
