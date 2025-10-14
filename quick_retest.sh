#!/bin/bash
cd ~/src/renterinsight_api
bundle exec rspec spec/controllers/api/portal/documents_controller_spec.rb spec/models/portal_document_spec.rb --format progress
