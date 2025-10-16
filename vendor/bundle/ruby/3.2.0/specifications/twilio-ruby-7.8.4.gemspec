# -*- encoding: utf-8 -*-
# stub: twilio-ruby 7.8.4 ruby lib

Gem::Specification.new do |s|
  s.name = "twilio-ruby".freeze
  s.version = "7.8.4"

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "documentation_uri" => "https://www.twilio.com/docs/libraries/reference/twilio-ruby/", "yard.run" => "yri" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Twilio API Team".freeze]
  s.date = "2025-10-14"
  s.description = "The official library for communicating with the Twilio REST API, building TwiML, and generating Twilio JWT Capability Tokens".freeze
  s.extra_rdoc_files = ["README.md".freeze, "LICENSE".freeze]
  s.files = ["LICENSE".freeze, "README.md".freeze]
  s.homepage = "https://github.com/twilio/twilio-ruby".freeze
  s.licenses = ["MIT".freeze]
  s.rdoc_options = ["--line-numbers".freeze, "--inline-source".freeze, "--title".freeze, "twilio-ruby".freeze, "--main".freeze, "README.md".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 2.0.0".freeze)
  s.rubygems_version = "3.4.20".freeze
  s.summary = "The official library for communicating with the Twilio REST API, building TwiML, and generating Twilio JWT Capability Tokens".freeze

  s.installed_by_version = "3.4.20" if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<jwt>.freeze, [">= 1.5", "< 4.0"])
  s.add_runtime_dependency(%q<nokogiri>.freeze, [">= 1.6", "< 2.0"])
  s.add_runtime_dependency(%q<faraday>.freeze, [">= 0.9", "< 3.0"])
  s.add_development_dependency(%q<bundler>.freeze, [">= 1.5", "< 3.0"])
  s.add_development_dependency(%q<equivalent-xml>.freeze, ["~> 0.6"])
  s.add_development_dependency(%q<fakeweb>.freeze, ["~> 1.3"])
  s.add_development_dependency(%q<rack>.freeze, ["~> 2.0"])
  s.add_development_dependency(%q<rake>.freeze, ["~> 13.0"])
  s.add_development_dependency(%q<rspec>.freeze, ["~> 3.0"])
  s.add_development_dependency(%q<yard>.freeze, ["~> 0.9.9"])
  s.add_development_dependency(%q<logger>.freeze, ["~> 1.4.2"])
end
