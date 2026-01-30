#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "irb"

require_relative "initialize"

puts "=" * 80
puts "Sidekiq::AsyncHttp Interactive Console"
puts "=" * 80
puts "Redis URL: #{AppConfig.redacted_redis_url}"
puts "=" * 80
puts ""

IRB.start
