#!/usr/bin/env ruby
# frozen_string_literal: true

# Performance Test for Dylan 1.0
# Compares serial vs. parallel requests
# Tests async/fiber-based concurrency

require 'net/http'
require 'benchmark'

HOST = 'localhost'
PORT = 8080  # Mac: 8080, Synology: 80

def make_request(path)
  start = Time.now
  response = Net::HTTP.get_response(HOST, path, PORT)
  duration = Time.now - start
  { path: path, status: response.code, duration: duration }
rescue => e
  { path: path, status: 'ERROR', duration: 0, error: e.message }
end

puts "=" * 70
puts "Dylan 1.0 Performance Test (Ruby 4.0)"
puts "=" * 70
puts

# Test 1: Single Requests (Baseline)
puts "Test 1: Single Requests (Baseline)"
puts "-" * 70

['/g/ruby', '/gh/rails/rails', '/1A22832D', '/monitor'].each do |path|
  result = make_request(path)
  puts "  #{path.ljust(20)} -> #{result[:status]} (#{(result[:duration] * 1000).round(1)}ms)"
end

puts

# Test 2: Parallel Fast Requests
puts "Test 2: Parallel Fast Requests (without Weather plugin)"
puts "-" * 70

paths = ['/g/ruby', '/gh/rails', '/wiki/Ruby', '/yt/async']

elapsed = Benchmark.realtime do
  threads = paths.map do |path|
    Thread.new { make_request(path) }
  end
  results = threads.map(&:value)

  results.each do |r|
    puts "  #{r[:path].ljust(20)} -> #{r[:status]} (#{(r[:duration] * 1000).round(1)}ms)"
  end
end

puts "  Total: #{(elapsed * 1000).round(1)}ms (parallel)"
puts "  Expected serial: ~#{(paths.count * 10).round(0)}ms"
puts

# Test 3: Slow Request + Fast Requests (Demo Async Advantage)
puts "Test 3: Slow Request (Weather) + Fast Requests simultaneously"
puts "-" * 70
puts "  Starting /weather/Berlin (2s) + 3x Fast Requests in parallel"
puts

elapsed = Benchmark.realtime do
  threads = [
    Thread.new { make_request('/weather/Berlin') },
    Thread.new { sleep 0.1; make_request('/g/async') },
    Thread.new { sleep 0.2; make_request('/gh/rails') },
    Thread.new { sleep 0.3; make_request('/wiki/Fiber') }
  ]
  results = threads.map(&:value)

  results.each do |r|
    puts "  #{r[:path].ljust(25)} -> #{r[:status]} (#{(r[:duration] * 1000).round(1)}ms)"
  end
end

puts
puts "  Total: #{(elapsed * 1000).round(1)}ms"
puts "  ✅ If <2100ms: Fast requests ran in PARALLEL (not blocked!)"
puts "  ❌ If >6000ms: Requests ran SERIALLY (blocked)"
puts

puts "=" * 70
puts "Interpretation:"
puts "  - Async Server (Dylan 1.0): Fast requests respond immediately (~3-10ms)"
puts "  - Sync Server: Fast requests wait for Weather (>2000ms)"
puts "  - Ruby 4.0 Fibers: Non-blocking I/O with Async::Task"
puts "=" * 70
