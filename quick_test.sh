#!/bin/bash
cd ~/src/renterinsight_api
bundle exec rspec spec/services/buyer_portal_service_spec.rb spec/controllers/api/portal/ --format documentation
