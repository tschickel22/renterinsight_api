#!/bin/bash
# Patch routes.rb to add portal projects route
cd /home/tschi/src/renterinsight_api
sed -i '/# Portal Service Tickets/i\      # Portal Project Progress\n      resources :projects, only: [:index, :show]\n' config/routes.rb
echo "✅ Portal projects route added"
grep -A2 "Portal Project Progress" config/routes.rb
