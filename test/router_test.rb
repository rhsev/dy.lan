# frozen_string_literal: true

# ruby test/router_test.rb
#
# Pins what a caller sees when the plugin that owns a path breaks. The router
# used to fall through to 404 — a plugin raising on every request looked like
# a missing route, which hid an encoding bug on images without LANG.

require 'minitest/autorun'
require 'async'
require_relative '../lib/plugin'
require_relative '../lib/router'
require_relative '../lib/response'

class RouterTest < Minitest::Test
  def setup
    Dylan::Plugin.clear_registered!
    @router = Dylan::Router.new
  end

  def plugin(regex, wait: 0.5, &body)
    Class.new(Dylan::Plugin) do
      pattern regex
      timeout wait
      define_method(:call) { |host, path, request| instance_exec(path, &body) }
    end.tap { @router.add_plugin(it) }
  end

  def get(path)
    response = nil
    capture_io { Sync { response = @router.call('dy.lan', path, nil) } }
    response
  end

  def test_answering_plugin_wins
    plugin(%r{^/ok$}) { Dylan::Response.text('ok') }

    assert_equal 200, get('/ok').status
  end

  def test_unmatched_path_is_404
    plugin(%r{^/ok$}) { Dylan::Response.text('ok') }

    assert_equal 404, get('/nope').status
  end

  def test_raising_plugin_is_500_not_404
    plugin(%r{^/boom$}) { raise 'broken' }

    assert_equal 500, get('/boom').status
  end

  def test_slow_plugin_is_504
    plugin(%r{^/slow$}, wait: 0.01) { sleep 0.1 }

    assert_equal 504, get('/slow').status
  end

  def test_later_plugin_still_answers_after_a_failure
    plugin(%r{^/x$}) { raise 'broken' }
    plugin(%r{^/x$}) { Dylan::Response.text('fallback') }

    assert_equal 200, get('/x').status
  end

  def test_disabled_plugin_is_503
    plugin(%r{^/boom$}) { raise 'broken' }
    Dylan::Router::ERROR_THRESHOLD.times { get('/boom') }

    assert_equal 503, get('/boom').status
    assert_equal 404, get('/other').status
  end
end
