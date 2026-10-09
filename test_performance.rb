#!/usr/bin/env ruby
# frozen_string_literal: true

# Performance Test for Dylan 1.1
# Latency of real routes, async concurrency, and a short load run.
#
#   DYLAN_HOST=localhost DYLAN_PORT=8080 ruby test_performance.rb
#
# Env:
#   DYLAN_HOST          server to test (default: localhost)
#   DYLAN_PORT          published port (default: 8080)
#   DYLAN_VHOST         Host header sent with every request (default: dy.lan).
#                       redirects.yaml only answers for its `domains:`, so without
#                       it every redirect route comes back 404.
#   DYLAN_LOAD_SECONDS  duration per load-test route, 0 skips Test 4 (default: 5)
#   DYLAN_LOAD_CLIENTS  concurrent keep-alive connections in Test 4 (default: 8)
#
# Exits 1 if any route answers with a status other than the expected one.

require 'net/http'

HOST         = ENV.fetch('DYLAN_HOST', 'localhost')
PORT         = ENV.fetch('DYLAN_PORT', '8080').to_i
VHOST        = ENV.fetch('DYLAN_VHOST', 'dy.lan')
LOAD_SECONDS = ENV.fetch('DYLAN_LOAD_SECONDS', '5').to_f
LOAD_CLIENTS = ENV.fetch('DYLAN_LOAD_CLIENTS', '8').to_i

# Routes every Dylan install serves: core plugins and the redirects shipped in
# config/redirects.yaml. (/monitor is left out: it 404s until cron has written
# data/monitor.md; /whoami only answers known milan agents.)
SINGLE   = { '/dylan/stats' => 200, '/stage' => 200, '/dylan/routes' => 200, '/g/ruby' => 302 }.freeze
PARALLEL = { '/g/ruby' => 302, '/gh/rails' => 302, '/wiki/Ruby' => 302, '/yt/async' => 302 }.freeze
LOAD     = %w[/dylan/stats /stage].freeze

$failures = []

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def make_request(path, expected = nil, http: nil)
  request = Net::HTTP::Get.new(path, 'Host' => VHOST)
  start = now
  response = http ? http.request(request) : Net::HTTP.start(HOST, PORT) { it.request(request) }
  result = { path: path, status: response.code.to_i, duration: now - start }
  $failures << "#{path}: #{result[:status]} (expected #{expected})" if expected && result[:status] != expected
  result
rescue => e
  $failures << "#{path}: #{e.class}: #{e.message}"
  { path: path, status: 'ERROR', duration: 0 }
end

def ms(seconds) = "#{(seconds * 1000).round(1)}ms"

def report(result, expected)
  mark = result[:status] == expected ? '✅' : '❌'
  puts "  #{mark} #{result[:path].ljust(20)} -> #{result[:status]} (#{ms(result[:duration])})"
end

def percentile(sorted, p) = sorted[((sorted.size - 1) * p).round]

puts "=" * 70
puts "Dylan 1.1 Performance Test (Ruby #{RUBY_VERSION})"
puts "Target: http://#{HOST}:#{PORT}  (Host: #{VHOST})"
puts "=" * 70
puts

# Test 1: Single Requests (Baseline)
puts "Test 1: Single Requests (Baseline)"
puts "-" * 70

SINGLE.each { |path, expected| report(make_request(path, expected), expected) }
puts

# Test 2: Parallel Fast Requests
puts "Test 2: Parallel Fast Requests (redirects)"
puts "-" * 70

start = now
results = PARALLEL.map { |path, expected| Thread.new { make_request(path, expected) } }.map(&:value)
elapsed = now - start
results.each { report(it, PARALLEL[it[:path]]) }
puts "  Total: #{ms(elapsed)} (parallel), serial sum: #{ms(results.sum { it[:duration] })}"
puts

# Test 3: Slow Request + Fast Requests (Demo Async Advantage)
puts "Test 3: Slow Request (/dylan/slow/2000) + Fast Requests simultaneously"
puts "-" * 70

start = now
threads = [
  Thread.new { make_request('/dylan/slow/2000', 200) },
  Thread.new { sleep 0.1; make_request('/g/async', 302) },
  Thread.new { sleep 0.2; make_request('/gh/rails', 302) },
  Thread.new { sleep 0.3; make_request('/wiki/Fiber', 302) }
]
results = threads.map(&:value)
elapsed = now - start
fast = results.drop(1)

results.each { report(it, it[:path].start_with?('/dylan/slow') ? 200 : 302) }
puts "  Total: #{ms(elapsed)}, slowest fast request: #{ms(fast.map { it[:duration] }.max)}"
if results.any? { it[:status] == 'ERROR' }
  puts "  ❌ Requests failed, concurrency not measured"
elsif fast.all? { it[:duration] < 0.5 }
  puts "  ✅ Fast requests answered while /dylan/slow was sleeping (not blocked)"
else
  puts "  ❌ A fast request waited on /dylan/slow (blocked)"
  $failures << 'Test 3: fast request blocked by /dylan/slow'
end
puts

# Test 4: Load (keep-alive connections, fixed duration)
if LOAD_SECONDS.positive?
  puts "Test 4: Load (#{LOAD_CLIENTS} keep-alive clients, #{LOAD_SECONDS}s per route)"
  puts "-" * 70

  LOAD.each do |path|
    deadline = now + LOAD_SECONDS
    workers = Array.new(LOAD_CLIENTS) do
      Thread.new do
        durations = []
        errors = 0
        begin
          Net::HTTP.start(HOST, PORT) do |http|
            while now < deadline
              result = make_request(path, http: http)
              result[:status] == 200 ? durations << result[:duration] : errors += 1
            end
          end
        rescue => e
          $failures << "Test 4 #{path}: #{e.class}: #{e.message}"
          errors += 1
        end
        [durations, errors]
      end
    end
    runs = workers.map(&:value)
    durations = runs.flat_map(&:first).sort
    errors = runs.sum(&:last)
    $failures << "Test 4 #{path}: #{errors} non-200 responses" if errors.positive?

    if durations.empty?
      puts "  ❌ #{path.ljust(20)} -> no successful requests"
    else
      puts "  #{errors.zero? ? '✅' : '❌'} #{path.ljust(20)} -> #{(durations.size / LOAD_SECONDS).round} req/s, " \
           "p50 #{ms(percentile(durations, 0.5))}, p99 #{ms(percentile(durations, 0.99))}, errors #{errors}"
    end
  end
  puts "  Note: the Ruby client shares one GVL and tops out early; compare images with wrk."
  puts
end

puts "=" * 70
if $failures.empty?
  puts "✅ All routes answered as expected"
else
  puts "❌ #{$failures.uniq.size} problem(s):"
  $failures.uniq.each { puts "  - #{it}" }
end
puts "=" * 70

exit($failures.empty? ? 0 : 1)
